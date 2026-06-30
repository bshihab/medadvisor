import Foundation
import FluidAudio

/// On-device speech-to-text via FluidAudio's Parakeet TDT (NVIDIA, CoreML/ANE).
/// Alternative to WhisperKit — typically much lower word-error rate and emits
/// native word-level timestamps (better doctor/patient alignment with the
/// diarizer). Model (~600MB) auto-downloads once, then runs offline.
///
/// Loads the model, transcribes, and releases it on return so it isn't held in
/// memory while other models (diarization, LLM) run.
@MainActor
final class ParakeetTranscriber: Transcribing {
    func transcribe(url: URL) async throws -> TranscriptResult {
        // `.v2` = English-only, highest recall. (`.v3` = 25-language multilingual.)
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)

        let samples = try AudioLoader.loadSamples(url: url, sampleRate: 16_000)
        let result = try await asr.transcribe(samples)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Parakeet gives per-token timings; aggregate to words, then group words
        // into phrase-level segments the diarizer can align by midpoint.
        let words = buildWordTimings(from: result.tokenTimings ?? [])
        var segments = Self.groupIntoSegments(words)

        // Fallback: no token timings → one segment spanning the whole clip so the
        // single-speaker path still shows a bubble.
        if segments.isEmpty, !text.isEmpty {
            let duration = Double(samples.count) / 16_000
            segments = [TranscriptSegment(text: text, start: 0, end: duration)]
        }

        return TranscriptResult(text: text, segments: segments)
    }

    /// Groups word timings into phrase-level segments: a new segment starts on a
    /// pause (> 0.8s gap), after sentence-ending punctuation, or every ~24 words.
    private static func groupIntoSegments(_ words: [WordTiming]) -> [TranscriptSegment] {
        guard !words.isEmpty else { return [] }

        var segments: [TranscriptSegment] = []
        var buffer: [WordTiming] = []

        func flush() {
            guard let first = buffer.first, let last = buffer.last else { return }
            let text = buffer.map { $0.word }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(TranscriptSegment(text: text,
                                                  start: first.startTime,
                                                  end: last.endTime))
            }
            buffer.removeAll(keepingCapacity: true)
        }

        for word in words {
            if let last = buffer.last {
                let gap = word.startTime - last.endTime
                let endsSentence = last.word.hasSuffix(".") || last.word.hasSuffix("?")
                    || last.word.hasSuffix("!")
                if gap > 0.8 || endsSentence || buffer.count >= 24 {
                    flush()
                }
            }
            buffer.append(word)
        }
        flush()
        return segments
    }
}
