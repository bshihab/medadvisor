import Foundation

/// One speaker's turn in the conversation.
struct TranscriptTurn: Codable, Equatable {
    let speaker: String   // "Speaker 1" / "Speaker 2" (or "Doctor"/"Patient" after enrollment)
    let text: String
}

/// Aligns Whisper transcript segments with diarization speaker segments and
/// groups them into conversation turns (for the chat UI + a labeled transcript).
enum SpeakerMerger {
    static func turns(segments whisper: [WhisperSegment], speakers: [SpeakerSegment]) -> [TranscriptTurn] {
        guard !whisper.isEmpty, !speakers.isEmpty else { return [] }

        // Map raw speaker ids to friendly, stable labels in order of appearance.
        var labelFor: [String: String] = [:]
        func label(_ id: String) -> String {
            if let existing = labelFor[id] { return existing }
            let new = "Speaker \(labelFor.count + 1)"
            labelFor[id] = new
            return new
        }

        func midpoint(_ s: SpeakerSegment) -> Double { (s.start + s.end) / 2 }
        func speaker(atMidpoint mid: Double) -> String {
            if let hit = speakers.first(where: { mid >= $0.start && mid <= $0.end }) {
                return hit.speakerId
            }
            var best = speakers[0]
            var bestDistance = abs(midpoint(best) - mid)
            for candidate in speakers.dropFirst() {
                let distance = abs(midpoint(candidate) - mid)
                if distance < bestDistance {
                    best = candidate
                    bestDistance = distance
                }
            }
            return best.speakerId
        }

        var turns: [TranscriptTurn] = []
        for segment in whisper {
            let mid = (segment.start + segment.end) / 2
            let speakerLabel = label(speaker(atMidpoint: mid))

            if let last = turns.last, last.speaker == speakerLabel {
                turns[turns.count - 1] = TranscriptTurn(speaker: speakerLabel,
                                                        text: last.text + " " + segment.text)
            } else {
                turns.append(TranscriptTurn(speaker: speakerLabel, text: segment.text))
            }
        }
        return turns
    }

    /// Number of distinct speakers in the diarization output.
    static func distinctSpeakerCount(_ speakers: [SpeakerSegment]) -> Int {
        Set(speakers.map { $0.speakerId }).count
    }
}
