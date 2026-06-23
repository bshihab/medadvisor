import Foundation
import Speech

/// A transcribed word with its start time (used to align with speaker segments).
struct TranscribedWord: Equatable {
    let text: String
    let start: Double
}

struct TranscriptionResult: Equatable {
    let text: String
    let words: [TranscribedWord]
}

/// On-device speech-to-text. `requiresOnDeviceRecognition = true` forces local
/// processing — nothing is sent to Apple's servers.
@MainActor
final class SpeechTranscriber {
    enum TranscriberError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let message): return message }
        }
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    func requestPermission() {
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    /// Transcribes a local audio file on-device, returning text + per-word timings.
    func transcribe(url: URL) async throws -> TranscriptionResult {
        guard let recognizer, recognizer.isAvailable else {
            throw TranscriberError.unavailable("Speech recognizer not available.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // We refuse to fall back to server recognition — on-device is required.
            throw TranscriberError.unavailable("On-device recognition unsupported on this device/locale.")
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                    return
                }
                guard let result, result.isFinal, !resumed else { return }
                resumed = true
                let words = result.bestTranscription.segments.map {
                    TranscribedWord(text: $0.substring, start: $0.timestamp)
                }
                continuation.resume(returning: TranscriptionResult(
                    text: result.bestTranscription.formattedString,
                    words: words))
            }
        }
    }
}
