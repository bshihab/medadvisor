import AVFoundation
import Foundation
import Speech

/// Records an encounter via AVAudioEngine. One mic tap does two things:
///  1. writes the audio to a file (the priority — feeds the accurate
///     post-stop transcription), and
///  2. when the Apple engine is selected, streams the audio to SpeechAnalyzer
///     (iOS 26) for a LIVE on-screen transcript.
///
/// The live-transcription path is wrapped defensively: if any part of it fails,
/// the recording still completes normally. (SpeechAnalyzer is the modern
/// long-form streaming engine — not the old flaky SFSpeechRecognizer.)
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    /// The length of the just-finished recording, so the analyze screen can show
    /// how long it was even though `elapsed` resets to 0 on stop.
    @Published var lastDuration: TimeInterval = 0
    @Published var level: Float = 0
    /// Rolling buffer of recent levels for the scrolling waveform (newest last).
    @Published var waveform: [Float] = []
    @Published var elapsed: TimeInterval = 0
    @Published var recordings: [URL] = []
    @Published var permissionDenied = false
    /// Live transcript while recording (Apple engine only): finalized paragraphs
    /// plus the in-progress (volatile) tail, styled separately Live Voicemail-style.
    @Published var liveFinal: String = ""
    @Published var liveVolatile: String = ""
    /// Finalized lines with the elapsed time they landed at, so the live view can
    /// show a timestamp on the left and the gaps between them reveal the pauses.
    @Published var liveLines: [LiveLine] = []
    /// True when live transcription is active this session.
    @Published var liveActive = false

    /// One finalized live-transcript line, stamped with when it landed.
    struct LiveLine: Identifiable, Equatable {
        let id: Int
        let time: TimeInterval   // seconds since recording started
        let text: String
    }

    private let engine = AVAudioEngine()
    private var currentURL: URL?
    private var startedAt: Date?
    private var bankedElapsed: TimeInterval = 0

    private static let maxWaveformSamples = 120

    /// State the audio tap thread owns. The tap's buffer is only guaranteed
    /// valid inside the callback, so file writes + conversion MUST happen there
    /// synchronously — never after an async hop (that caused corrupt writes and
    /// crashes on longer recordings).
    private final class Capture: @unchecked Sendable {
        var file: AVAudioFile?
        var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
        var analyzerFormat: AVAudioFormat?
        var converter: AVAudioConverter?
        var paused = false
    }
    private let capture = Capture()

    // Live transcription (SpeechAnalyzer)
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var recognizerTask: Task<Void, Never>?
    private var finalizedText = ""

    func requestPermission() {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in self.permissionDenied = !granted }
        }
    }

    func toggle() { isRecording ? stop() : start() }

    func pause() {
        guard isRecording, !isPaused else { return }
        capture.paused = true
        if let startedAt { bankedElapsed += Date().timeIntervalSince(startedAt) }
        startedAt = nil
        level = 0
        isPaused = true
    }

    func resume() {
        guard isRecording, isPaused else { return }
        capture.paused = false
        startedAt = Date()
        isPaused = false
    }

    func togglePause() { isPaused ? resume() : pause() }

    /// Deletes a recorded file (called after analysis — no raw audio kept).
    func deleteRecording(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        recordings.removeAll { $0 == url }
    }

    // MARK: - Start / stop

    private func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)

            // File to write (WAV/PCM — read reliably by WhisperKit/diarizer later).
            let url = Self.makeFileURL()
            capture.file = try AVAudioFile(forWriting: url, settings: format.settings)
            capture.paused = false
            currentURL = url

            // Optional live transcription (Apple engine only). Best-effort.
            let wantLive = (TranscriptionEngine.current == .apple)
            if wantLive, #available(iOS 26.0, *) {
                Task { await self.setupLiveTranscription() }
            }

            let capture = self.capture
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard !capture.paused else { return }
                // Synchronous work while the buffer is valid (tap thread):
                try? capture.file?.write(from: buffer)
                if let builder = capture.inputBuilder, let fmt = capture.analyzerFormat,
                   let converted = Self.convert(buffer, to: fmt, using: &capture.converter) {
                    builder.yield(AnalyzerInput(buffer: converted))
                }
                // Lightweight UI numbers hop to the main actor.
                let level = Self.rms(buffer)
                Task { @MainActor in self?.updateMeter(level) }
            }

            engine.prepare()
            try engine.start()

            startedAt = Date()
            bankedElapsed = 0
            waveform = []
            liveFinal = ""
            liveVolatile = ""
            liveLines = []
            finalizedText = ""
            isPaused = false
            isRecording = true
        } catch {
            print("Recording failed to start: \(error)")
        }
    }

    private func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // Finish the file.
        capture.file = nil
        if let url = currentURL { recordings.insert(url, at: 0) }
        currentURL = nil

        // Finish live transcription.
        capture.inputBuilder?.finish()
        capture.inputBuilder = nil
        capture.analyzerFormat = nil
        capture.converter = nil
        let analyzer = self.analyzer
        Task { try? await analyzer?.finalizeAndFinishThroughEndOfInput() }
        recognizerTask?.cancel(); recognizerTask = nil
        transcriber = nil; self.analyzer = nil

        isRecording = false
        isPaused = false
        liveActive = false
        level = 0
        lastDuration = elapsed   // remember the length for the analyze screen
        elapsed = 0
        startedAt = nil
        bankedElapsed = 0
        waveform = []
        liveVolatile = ""
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // MARK: - UI meter (main actor; audio work stays on the tap thread)

    private func updateMeter(_ newLevel: Float) {
        guard isRecording, !isPaused else { return }
        level = newLevel
        // Light exponential smoothing so spikes don't make the bars jump.
        let smoothed = (waveform.last ?? newLevel) * 0.4 + newLevel * 0.6
        waveform.append(smoothed)
        if waveform.count > Self.maxWaveformSamples {
            waveform.removeFirst(waveform.count - Self.maxWaveformSamples)
        }
        let running = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        elapsed = bankedElapsed + running
    }

    // MARK: - Live transcription setup

    @available(iOS 26.0, *)
    private func setupLiveTranscription() async {
        do {
            let t = SpeechTranscriber(locale: Locale.current,
                                      transcriptionOptions: [],
                                      reportingOptions: [.volatileResults],
                                      attributeOptions: [])
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                try await req.downloadAndInstall()
            }
            let a = SpeechAnalyzer(modules: [t])
            let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
            let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
            try await a.start(inputSequence: stream)

            self.transcriber = t
            self.analyzer = a
            capture.analyzerFormat = fmt
            capture.inputBuilder = builder
            self.liveActive = true

            self.recognizerTask = Task { [weak self] in
                do {
                    for try await result in t.results {
                        guard let self else { return }
                        let piece = String(result.text.characters)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !piece.isEmpty else { continue }
                        if result.isFinal {
                            // Each finalized chunk becomes its own paragraph,
                            // like Live Voicemail's phrase blocks — stamped with
                            // the current elapsed time for the left-hand column.
                            self.finalizedText += (self.finalizedText.isEmpty ? "" : "\n\n") + piece
                            self.liveFinal = self.finalizedText
                            self.liveLines.append(LiveLine(id: self.liveLines.count,
                                                           time: self.elapsed, text: piece))
                            self.liveVolatile = ""
                        } else {
                            self.liveVolatile = piece
                        }
                    }
                } catch {
                    // Live text is cosmetic — ignore failures, recording continues.
                }
            }
        } catch {
            // Setup failed → no live text, but recording is unaffected.
            liveActive = false
        }
    }

    // MARK: - Helpers

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { let s = data[0][i]; sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        return max(0, min(1, rms * 20))
    }

    /// Convert a mic buffer to the analyzer's format (cached converter).
    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer,
                                to format: AVAudioFormat,
                                using converter: inout AVAudioConverter?) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return err == nil ? out : nil
    }

    private static func makeFileURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return docs.appendingPathComponent("encounter-\(stamp).wav")
    }
}
