import Foundation
import FluidAudio

/// On-device speech-to-text via FluidAudio's Parakeet TDT (NVIDIA, CoreML/ANE).
/// Alternative to WhisperKit — typically much lower word-error rate and emits
/// per-token timestamps we aggregate to words (better doctor/patient alignment
/// with the diarizer). Model (~600MB) auto-downloads once, then runs offline.
///
/// Loads the model, transcribes, and releases it on return so it isn't held in
/// memory while other models (diarization, LLM) run.
///
/// Written against FluidAudio v0.15.4: transcribe takes an inout TdtDecoderState
/// and there's no buildWordTimings helper, so we aggregate tokens ourselves.
@MainActor
final class ParakeetTranscriber: Transcribing {
    func transcribe(url: URL) async throws -> TranscriptResult {
        // `.v2` = English-only, highest recall. (`.v3` = 25-language multilingual.)
        // Download into a directory we own so Settings can detect/delete it.
        let models = try await AsrModels.downloadAndLoad(to: AppModelPaths.parakeetBase, version: .v2)
        let asr = AsrManager()
        try await asr.loadModels(models)

        let samples = try AudioLoader.loadSamples(url: url, sampleRate: 16_000)
        var decoderState = try TdtDecoderState()
        let result = try await asr.transcribe(samples, decoderState: &decoderState)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Parakeet gives per-token timings; aggregate to words, then group words
        // into phrase-level segments the diarizer can align by midpoint.
        let words = Self.buildWords(from: result.tokenTimings ?? [])
        var segments = Self.groupIntoSegments(words)

        // Fallback: no token timings → one segment spanning the clip so the
        // single-speaker path still shows a bubble.
        if segments.isEmpty, !text.isEmpty {
            segments = [TranscriptSegment(text: text, start: 0, end: result.duration)]
        }

        return TranscriptResult(text: text, segments: segments)
    }

    /// A word reconstructed from SentencePiece sub-word tokens.
    private struct Word {
        let text: String
        let start: Double
        let end: Double
    }

    /// Aggregates token timings into words. Parakeet's SentencePiece tokenizer
    /// marks a new word with a leading `▁` (U+2581) or a leading space.
    private static func buildWords(from tokens: [TokenTiming]) -> [Word] {
        var words: [Word] = []
        var current = ""
        var start = 0.0
        var end = 0.0

        func flush() {
            let cleaned = current
                .replacingOccurrences(of: "\u{2581}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                words.append(Word(text: cleaned, start: start, end: end))
            }
            current = ""
        }

        for tok in tokens {
            let piece = tok.token
            let startsNewWord = piece.hasPrefix("\u{2581}") || piece.hasPrefix(" ")
            if startsNewWord && !current.isEmpty { flush() }
            if current.isEmpty { start = tok.startTime }
            current += piece
            end = tok.endTime
        }
        flush()
        return words
    }

    /// Groups words into phrase-level segments: a new segment starts on a pause
    /// (> 0.8s gap), after sentence-ending punctuation, or every ~24 words.
    private static func groupIntoSegments(_ words: [Word]) -> [TranscriptSegment] {
        guard !words.isEmpty else { return [] }

        var segments: [TranscriptSegment] = []
        var buffer: [Word] = []

        func flush() {
            guard let first = buffer.first, let last = buffer.last else { return }
            let text = buffer.map { $0.text }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(TranscriptSegment(text: text,
                                                  start: first.start,
                                                  end: last.end))
            }
            buffer.removeAll(keepingCapacity: true)
        }

        for word in words {
            if let last = buffer.last {
                let gap = word.start - last.end
                let endsSentence = last.text.hasSuffix(".") || last.text.hasSuffix("?")
                    || last.text.hasSuffix("!")
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
