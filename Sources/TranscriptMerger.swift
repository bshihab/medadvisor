import Foundation

/// Merges word-level transcription (with timestamps) and speaker time-segments
/// into a speaker-labeled transcript:
///
///   Speaker 1: Good morning, how are you feeling today?
///   Speaker 2: A bit better, thanks.
///
/// If there are no segments or no word timings, falls back to the plain transcript.
enum TranscriptMerger {
    static func labeled(words: [TranscribedWord], segments: [SpeakerSegment]) -> String {
        guard !segments.isEmpty, !words.isEmpty else {
            return words.map(\.text).joined(separator: " ")
        }

        var labelFor: [String: String] = [:]
        func label(for id: String) -> String {
            if let existing = labelFor[id] { return existing }
            let new = "Speaker \(labelFor.count + 1)"
            labelFor[id] = new
            return new
        }
        func speaker(at time: Double) -> String {
            if let hit = segments.first(where: { time >= $0.start && time <= $0.end }) {
                return hit.speakerId
            }
            return segments.min(by: { abs(mid($0) - time) < abs(mid($1) - time) })?.speakerId ?? "?"
        }

        var lines: [String] = []
        var currentId: String?
        var buffer: [String] = []
        for word in words {
            let id = speaker(at: word.start)
            if id != currentId {
                flush(&lines, currentId, buffer, label)
                currentId = id
                buffer = [word.text]
            } else {
                buffer.append(word.text)
            }
        }
        flush(&lines, currentId, buffer, label)
        return lines.joined(separator: "\n")
    }

    private static func flush(_ lines: inout [String], _ id: String?, _ buffer: [String],
                              _ label: (String) -> String) {
        guard let id, !buffer.isEmpty else { return }
        lines.append("\(label(id)): \(buffer.joined(separator: " "))")
    }

    private static func mid(_ s: SpeakerSegment) -> Double { (s.start + s.end) / 2 }
}
