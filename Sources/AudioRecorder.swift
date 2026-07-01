import AVFoundation
import Foundation

/// Records an encounter to a clean AAC `.m4a` using AVAudioRecorder — the
/// standard, reliable way to capture audio (no audio-engine / Apple live-STT
/// flakiness). WhisperKit transcribes the whole file afterward.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var level: Float = 0
    /// Rolling buffer of recent levels for the scrolling waveform (newest last).
    @Published var waveform: [Float] = []
    @Published var elapsed: TimeInterval = 0
    @Published var recordings: [URL] = []
    @Published var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var startedAt: Date?
    /// Elapsed time banked across pauses (the current running span is added live).
    private var bankedElapsed: TimeInterval = 0

    private static let maxWaveformSamples = 120

    func requestPermission() {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in self.permissionDenied = !granted }
        }
    }

    func toggle() { isRecording ? stop() : start() }

    /// Pause without finishing the recording; audio resumes into the same file.
    func pause() {
        guard isRecording, !isPaused else { return }
        recorder?.pause()
        if let startedAt { bankedElapsed += Date().timeIntervalSince(startedAt) }
        startedAt = nil
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
        isPaused = true
    }

    /// Resume a paused recording.
    func resume() {
        guard isRecording, isPaused else { return }
        recorder?.record()
        startedAt = Date()
        isPaused = false
        startMetering()
    }

    func togglePause() { isPaused ? resume() : pause() }

    /// Deletes a recorded file (called after analysis — no raw audio kept).
    func deleteRecording(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        recordings.removeAll { $0 == url }
    }

    private func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let url = Self.makeFileURL()
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            r.record()
            recorder = r
            startedAt = Date()
            bankedElapsed = 0
            waveform = []
            isPaused = false
            isRecording = true
            startMetering()
        } catch {
            print("Recording failed to start: \(error)")
        }
    }

    private func stop() {
        recorder?.stop()
        if let url = recorder?.url { recordings.insert(url, at: 0) }
        recorder = nil
        meterTimer?.invalidate()
        meterTimer = nil
        isRecording = false
        isPaused = false
        level = 0
        elapsed = 0
        startedAt = nil
        bankedElapsed = 0
        waveform = []
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func startMetering() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMeter() }
        }
    }

    private func updateMeter() {
        guard let recorder else { return }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        let normalized = max(0, min(1, pow(10, db / 20)))
        level = normalized

        waveform.append(normalized)
        if waveform.count > Self.maxWaveformSamples {
            waveform.removeFirst(waveform.count - Self.maxWaveformSamples)
        }

        let running = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        elapsed = bankedElapsed + running
    }

    private static func makeFileURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return docs.appendingPathComponent("encounter-\(stamp).m4a")
    }
}
