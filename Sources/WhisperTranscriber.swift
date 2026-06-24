import Foundation
import WhisperKit

/// On-device speech-to-text via WhisperKit (Whisper running through Core ML).
/// More accurate and format-robust than Apple's recognizer. The model
/// auto-downloads on first use (needs network once), then runs offline.
///
/// NOTE: written against WhisperKit 1.0.0. If the transcribe call signature
/// differs in this version, paste the error and we'll adjust.
@MainActor
final class WhisperTranscriber {
    /// English base model — good accuracy/speed on-device. Bump to "small.en"
    /// for higher accuracy at the cost of speed.
    private let modelName = "base.en"

    /// Loads Whisper, transcribes, and releases it on return — so the Whisper
    /// model is NOT held in memory while the LLM runs (avoids OOM crashes).
    func transcribe(url: URL) async throws -> String {
        let pipe = try await WhisperKit(WhisperKitConfig(model: modelName))
        let results = try await pipe.transcribe(audioPath: url.path)
        return results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
