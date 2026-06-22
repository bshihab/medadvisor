import AVFoundation
import Foundation

/// M0 recorder: captures a consultation to a local file with live level metering.
/// Everything stays on-device — the file is written to the app's documents directory.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    /// Normalized 0...1 input level for the UI meter.
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    /// Local file URLs of completed recordings this session.
    @Published var recordings: [URL] = []
    @Published var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var startedAt: Date?

    func requestPermission() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                self?.permissionDenied = !granted
            }
        }
    }

    func toggle() {
        isRecording ? stop() : start()
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
            isRecording = true
            startMetering()
        } catch {
            // M0: surface failures during the spike; replace with proper handling later.
            print("Recording failed to start: \(error)")
        }
    }

    private func stop() {
        recorder?.stop()
        if let url = recorder?.url {
            recordings.insert(url, at: 0)
        }
        recorder = nil
        meterTimer?.invalidate()
        meterTimer = nil
        isRecording = false
        level = 0
        elapsed = 0
        startedAt = nil
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
        // averagePower is in dB (-160...0). Convert to a linear 0...1 amplitude.
        let db = recorder.averagePower(forChannel: 0)
        level = max(0, min(1, pow(10, db / 20)))
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
    }

    private static func makeFileURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Timestamped name; no PHI in the filename.
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return docs.appendingPathComponent("encounter-\(stamp).m4a")
    }
}
