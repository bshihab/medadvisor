import Foundation
import AVFoundation
import Speech

/// On-device speech-to-text via Apple's SpeechAnalyzer (iOS 26+). No model
/// download — the OS ships/downloads the assets.
///
/// Built on the exact SpeechAnalyzer flow proven in tools/stt-benchmark
/// (AppleTranscribe.swift), which compiled and ran. NOTE: this version does NOT
/// extract per-word timestamps yet (the `.audioTimeRange` attribute API didn't
/// resolve on the iOS SDK), so it returns one whole-file segment. That means the
/// 2-speaker diarization split won't align well when Apple is the engine — use
/// Whisper/Parakeet for multi-speaker recordings until word timing is wired up.
@available(iOS 26.0, *)
@MainActor
final class AppleSpeechTranscriber: Transcribing {
    func transcribe(url: URL) async throws -> TranscriptResult {
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Ensure the on-device model assets are installed (one time).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        var fullText = ""
        let collector = Task {
            for try await result in transcriber.results {
                fullText += String(result.text.characters)
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
        let duration = Double(file.length) / max(1, file.fileFormat.sampleRate)
        let segments = text.isEmpty ? [] : [TranscriptSegment(text: text, start: 0, end: duration)]
        return TranscriptResult(text: text, segments: segments)
    }
}
