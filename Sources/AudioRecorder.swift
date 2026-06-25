import AVFoundation
import Foundation
import Speech

/// Records an encounter with AVAudioEngine so we can do two things at once:
///  1. Write the audio to a file (used later for diarization + accurate STT).
///  2. Stream a LIVE on-device transcript so the user sees what's being captured.
///
/// Not `@MainActor`: the audio tap runs on a real-time thread, so we publish
/// UI updates via the main queue explicitly.
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    @Published var liveText: String = ""
    /// Finalized phrases (one per pause) — rendered as chat bubbles during recording.
    @Published var liveUtterances: [String] = []
    /// The phrase currently being spoken (a "forming" bubble).
    @Published var livePartial: String = ""
    @Published var recordings: [URL] = []
    @Published var permissionDenied = false

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var currentURL: URL?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var startedAt: Date?
    private var timer: Timer?

    /// Text committed from finalized segments, plus the current in-progress
    /// partial. The live display is their combination — so the transcript grows
    /// across pauses instead of resetting.
    private var accumulatedText = ""
    private var currentPartial = ""

    func requestPermission() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { self.permissionDenied = !granted }
        }
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    func toggle() { isRecording ? stop() : start() }

    /// Deletes a recorded file from disk (called after analysis — no raw audio kept).
    func deleteRecording(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        DispatchQueue.main.async { self.recordings.removeAll { $0 == url } }
    }

    // MARK: - Start / stop

    private func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Audio session error: \(error)")
            return
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        // File for accurate transcription. Use AAC/.m4a — the format Apple's
        // file-based recognizer reads reliably (a float .caf came back empty).
        let url = Self.makeFileURL()
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ]
        do {
            file = try AVAudioFile(forWriting: url, settings: fileSettings)
        } catch {
            print("Audio file error: \(error)")
            return
        }
        currentURL = url

        // Live on-device transcript — ONLY if on-device recognition is supported,
        // so we never stream audio to a server.
        accumulatedText = ""
        currentPartial = ""
        liveUtterances = []
        livePartial = ""
        startRecognition()

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            try? self.file?.write(from: buffer)
            let lvl = Self.level(from: buffer)
            DispatchQueue.main.async { self.level = lvl }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("Engine start error: \(error)")
            return
        }

        startedAt = Date()
        isRecording = true
        liveText = ""
        level = 0
        startTimer()
    }

    private func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        file = nil

        if let url = currentURL { recordings.insert(url, at: 0) }
        currentURL = nil

        timer?.invalidate()
        timer = nil
        isRecording = false
        level = 0
        elapsed = 0
        startedAt = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Starts (or restarts) an on-device recognition task. We restart after each
    /// finalized segment (which the recognizer emits on a pause) so the live
    /// transcript keeps accumulating instead of resetting.
    private func startRecognition() {
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                // All live state is updated on main so @Published is safe.
                DispatchQueue.main.async {
                    self.currentPartial = text
                    self.livePartial = text
                    self.liveText = self.combinedText()
                    if isFinal {
                        self.commitPartial()
                        self.restartRecognition()
                    }
                }
            } else if error != nil {
                // The recognizer often errors on a pause — commit what we have
                // BEFORE restarting so the text isn't wiped.
                DispatchQueue.main.async {
                    self.commitPartial()
                    self.restartRecognition()
                }
            }
        }
    }

    private func combinedText() -> String {
        if accumulatedText.isEmpty { return currentPartial }
        if currentPartial.isEmpty { return accumulatedText }
        return accumulatedText + " " + currentPartial
    }

    /// Called on main. Turns the in-progress phrase into a finalized bubble.
    private func commitPartial() {
        let phrase = currentPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !phrase.isEmpty { liveUtterances.append(phrase) }
        accumulatedText = combinedText()
        currentPartial = ""
        livePartial = ""
    }

    private func restartRecognition() {
        DispatchQueue.main.async {
            guard self.isRecording else { return }
            self.task = nil
            self.request = nil
            self.startRecognition()
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            self.elapsed = Date().timeIntervalSince(startedAt)
        }
    }

    // MARK: - Helpers

    private static func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let channel = data[0]
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        return min(1, rms * 20)   // gain so normal speech fills the meter
    }

    private static func makeFileURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return docs.appendingPathComponent("encounter-\(stamp).m4a")
    }
}
