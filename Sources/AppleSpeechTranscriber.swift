import Foundation
import AVFoundation
import Speech

/// On-device speech-to-text via Apple's SpeechAnalyzer (iOS 26+). No model
/// download — the OS ships/downloads the assets.
///
/// Built on the exact SpeechAnalyzer flow proven in tools/stt-benchmark
/// (AppleTranscribe.swift), which compiled and ran. Returns one whole-file
/// segment. Speaker separation does not need per-word timings here: the PRIMARY
/// path uses the live transcript's own pause-segmented lines (see
/// EncounterProcessor), and this file transcription is only the fallback.
///
/// An earlier version of this comment claimed the `.audioTimeRange` attribute
/// API "didn't resolve on the iOS SDK". That was wrong — checked against the SDK
/// interface, `SpeechTranscriber.ResultAttributeOption.audioTimeRange` exists and
/// is available iOS 26.0+. The attribute was missing from results because
/// `attributeOptions` below is empty, and attributes are only attached when
/// requested. Left unrequested deliberately (nothing on this path consumes
/// timings) but it is there if ever needed.
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
