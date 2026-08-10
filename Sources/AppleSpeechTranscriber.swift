import Foundation
import AVFoundation
import Speech

/// On-device speech-to-text via Apple's SpeechAnalyzer (iOS 26+). No model
/// download — the OS ships/downloads the assets.
///
/// Built on the exact SpeechAnalyzer flow proven in tools/stt-benchmark
/// (AppleTranscribe.swift), which compiled and ran. Returns one whole-file
/// segment; speaker separation does not need per-word timings, since the primary
/// path uses the LIVE transcript's pause-segmented lines (see EncounterProcessor)
/// and this file transcription is only the fallback.
///
/// CORRECTION to an earlier note here: it claimed `.audioTimeRange` "didn't
/// resolve on the iOS SDK". It resolves fine — `SpeechTranscriber.ResultAttributeOption`
/// has an `.audioTimeRange` case, available iOS 26.0+. The attribute was absent
/// from results because `attributeOptions` was empty, and attributes are only
/// attached when requested. Left unrequested here on purpose (nothing consumes
/// timings on this path) but it is available if ever needed.
@available(iOS 26.0, *)
@MainActor
final class AppleSpeechTranscriber: Transcribing {
    func transcribe(url: URL) async throws -> TranscriptResult {
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [])

        // Bias recognition toward clinical vocabulary. Untouched, the recogniser
        // renders drug names as whatever common word sounds closest — measured on
        // real recordings: "Parasitamo" for paracetamol, "Nexoprin" for naproxen,
        // "I'm proven" for Ibuprofen, "ideology" for aetiology. Those land inside
        // the clinician's treatment explanation, which is what `accurate_info` is
        // graded on, so a mis-heard drug name can cost a criterion the clinician met.
        //
        // Set via setContext rather than the initialiser: init(modules:options:)
        // takes no analysisContext, and the overloads that do also demand the
        // input up front (inputAudioFile:/inputSequence:), which would mean
        // restructuring this method.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings = [.general: ClinicalVocabulary.all]
        try await analyzer.setContext(context)

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
