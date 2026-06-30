import Foundation
import WhisperKit

/// On-device speech-to-text via WhisperKit (Whisper through Core ML).
/// Loads the model, transcribes, and releases it on return so it isn't held in
/// memory while other models (diarization, LLM) run.
@MainActor
final class WhisperTranscriber: Transcribing {
    /// English model. `small.en` (~244M) is the accuracy/speed sweet spot on
    /// modern iPhones — far fewer errors than tiny.en. Whisper is released
    /// before the LLM loads and runs on the ANE, so we have the memory headroom.
    /// (Step up to "large-v3-turbo" for max accuracy at a few extra seconds.)
    private let modelName = "small.en"

    func transcribe(url: URL) async throws -> TranscriptResult {
        let pipe = try await WhisperKit(WhisperKitConfig(model: modelName))
        let results = try await pipe.transcribe(audioPath: url.path)

        let segments = results
            .flatMap { $0.segments }
            .map {
                TranscriptSegment(text: Self.cleanTokens($0.text),
                                  start: Double($0.start),
                                  end: Double($0.end))
            }
            .filter { !$0.text.isEmpty }

        let text = Self.cleanTokens(results.map { $0.text }.joined(separator: " "))

        return TranscriptResult(text: text, segments: segments)
    }

    /// Strips Whisper special/timestamp tokens like `<|0.00|>`, `<|en|>`, and
    /// stray `<7>` / `<>` that otherwise show up around sentences.
    private static func cleanTokens(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "<\\|[^>]*\\|>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        // Collapse any double spaces left behind.
        t = t.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
