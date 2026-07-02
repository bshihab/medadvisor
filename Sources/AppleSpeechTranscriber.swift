import Foundation
import AVFoundation
import Speech

/// On-device speech-to-text via Apple's SpeechAnalyzer (iOS 26+). No model
/// download — the OS ships/downloads the assets. We request per-run audio time
/// ranges so the transcript still carries timestamps for diarization alignment.
///
/// Built on the same SpeechAnalyzer flow proven in tools/stt-benchmark. If the
/// timestamp attribute yields nothing, we fall back to a single whole-file
/// segment so transcription still works (single-speaker view).
@available(iOS 26.0, *)
@MainActor
final class AppleSpeechTranscriber: Transcribing {
    func transcribe(url: URL) async throws -> TranscriptResult {
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Ensure the on-device model assets are installed (one time).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        // Collect text + timed word fragments as results stream in.
        var fullText = ""
        var fragments: [(text: String, start: Double, end: Double)] = []
        let collector = Task {
            for try await result in transcriber.results {
                let attributed = result.text
                fullText += String(attributed.characters)
                for run in attributed.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let piece = String(attributed[run.range].characters)
                    fragments.append((piece, range.start.seconds, range.end.seconds))
                }
            }
        }

        let file = try AVAudioFile(forReading: url)
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        _ = try await collector.value

        let text = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        var segments = Self.groupIntoSegments(fragments)
        if segments.isEmpty, !text.isEmpty {
            let duration = Double(file.length) / file.fileFormat.sampleRate
            segments = [TranscriptSegment(text: text, start: 0, end: duration)]
        }
        return TranscriptResult(text: text, segments: segments)
    }

    /// Group timed fragments into phrase-level segments (pause > 0.8s, sentence
    /// end, or ~24 words) so the diarizer can align by midpoint.
    private static func groupIntoSegments(
        _ fragments: [(text: String, start: Double, end: Double)]
    ) -> [TranscriptSegment] {
        guard !fragments.isEmpty else { return [] }
        var segments: [TranscriptSegment] = []
        var buffer: [(text: String, start: Double, end: Double)] = []

        func flush() {
            guard let first = buffer.first, let last = buffer.last else { return }
            let text = buffer.map { $0.text }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(TranscriptSegment(text: text, start: first.start, end: last.end))
            }
            buffer.removeAll(keepingCapacity: true)
        }

        for frag in fragments {
            if let last = buffer.last {
                let gap = frag.start - last.end
                let ends = last.text.hasSuffix(".") || last.text.hasSuffix("?") || last.text.hasSuffix("!")
                if gap > 0.8 || ends || buffer.count >= 24 { flush() }
            }
            buffer.append(frag)
        }
        flush()
        return segments
    }
}
