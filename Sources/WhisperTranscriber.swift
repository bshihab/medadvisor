import Foundation
import WhisperKit

/// A transcribed segment (phrase) with its time span — used to align text with
/// speaker segments from diarization.
struct WhisperSegment: Equatable {
    let text: String
    let start: Double
    let end: Double
}

struct WhisperResult: Equatable {
    let text: String
    let segments: [WhisperSegment]
}

/// On-device speech-to-text via WhisperKit (Whisper through Core ML).
/// Loads the model, transcribes, and releases it on return so it isn't held in
/// memory while other models (diarization, LLM) run.
@MainActor
final class WhisperTranscriber {
    /// Smallest English model — lowest memory + fastest on-device.
    private let modelName = "tiny.en"

    func transcribe(url: URL) async throws -> WhisperResult {
        let pipe = try await WhisperKit(WhisperKitConfig(model: modelName))
        let results = try await pipe.transcribe(audioPath: url.path)

        let segments = results
            .flatMap { $0.segments }
            .map {
                WhisperSegment(text: $0.text.trimmingCharacters(in: .whitespaces),
                               start: Double($0.start),
                               end: Double($0.end))
            }
            .filter { !$0.text.isEmpty }

        let text = results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return WhisperResult(text: text, segments: segments)
    }
}
