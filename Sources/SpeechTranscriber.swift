import Foundation
import Speech

/// M0 STT spike: transcribes a recorded file fully on-device.
/// `requiresOnDeviceRecognition = true` forces local processing — nothing is sent to Apple's servers.
/// Verify by transcribing in airplane mode.
@MainActor
final class SpeechTranscriber: ObservableObject {
    enum State: Equatable {
        case idle
        case transcribing
        case done(String)
        case unavailable(String)
    }

    @Published var state: State = .idle

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    func requestPermission() {
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    /// Transcribes the given local audio file on-device.
    func transcribe(url: URL) {
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable("Speech recognizer not available.")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // We refuse to fall back to server recognition — on-device is a hard requirement.
            state = .unavailable("On-device recognition unsupported on this device/locale.")
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        state = .transcribing
        recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.state = .unavailable("Transcription failed: \(error.localizedDescription)")
                    return
                }
                if let result, result.isFinal {
                    self.state = .done(result.bestTranscription.formattedString)
                }
            }
        }
    }

    func reset() { state = .idle }
}
