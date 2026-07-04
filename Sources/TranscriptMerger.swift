import Foundation

/// One speaker's turn in the conversation.
struct TranscriptTurn: Codable, Equatable {
    let speaker: String   // "Doctor" / "Patient", or "Speaker 1" for a solo recording
    let text: String
}

/// Speaker separation without diarization: we split the (single-speaker) ASR
/// transcript into short utterances, ask the LLM to tag each Doctor/Patient
/// (see PromptBuilder.speakerAttributionPrompt), then merge consecutive
/// same-role utterances back into turns. This replaced FluidAudio diarization,
/// which was unreliable and needed timed segments the Apple engine doesn't give.
enum SpeakerAttribution {
    /// The utterance units to label. Prefer the engine's own timed segments
    /// (Whisper); fall back to sentence-splitting the flat text (Apple returns
    /// one segment, so this is where its utterances come from).
    static func utterances(from result: TranscriptResult) -> [String] {
        let fromSegments = result.segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if fromSegments.count >= 2 { return fromSegments }
        return sentences(result.text)
    }

    /// Split flat text into sentence-ish utterances on ., ?, ! boundaries.
    /// Keeps the terminator; drops empties.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "?" || ch == "!" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// Merge consecutive utterances that share a role into turns. `roles` is
    /// aligned to `utterances`; a nil role inherits the previous turn's speaker
    /// (models occasionally skip a line).
    static func turns(utterances: [String], roles: [String?]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        for (i, text) in utterances.enumerated() {
            let role = roles.indices.contains(i) ? roles[i] : nil
            let speaker = role ?? turns.last?.speaker ?? "Doctor"
            if let last = turns.last, last.speaker == speaker {
                turns[turns.count - 1] = TranscriptTurn(speaker: speaker,
                                                        text: last.text + " " + text)
            } else {
                turns.append(TranscriptTurn(speaker: speaker, text: text))
            }
        }
        return turns
    }
}
