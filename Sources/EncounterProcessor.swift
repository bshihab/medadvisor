import Foundation
import UIKit

/// Orchestrates the on-device pipeline for one recording:
/// transcribe (Apple) → LLM speaker attribution → conversation turns →
/// redact → score each criterion → summary.
///
/// The transcriber is released before the LLM loads, so only one big model is
/// resident at a time; the LLM then does both attribution and scoring.
@MainActor
final class EncounterProcessor: ObservableObject {
    enum Stage: Equatable {
        case idle
        case transcribing
        case identifyingSpeakers
        case redacting
        case preparingModel(Double)   // first-run model download (fraction 0...1)
        case scoring(done: Int, total: Int)
        case summarizing
        case done(ConsultationFeedback)
        case error(String)
    }

    @Published var stage: Stage = .idle
    @Published var redactedTranscript: String = ""
    /// Redacted, speaker-labeled turns for the chat view (empty if 1 speaker).
    @Published var transcriptTurns: [TranscriptTurn] = []
    /// Per-criterion results as they're scored — drives the live-filling rubric.
    @Published var liveResults: [CriterionResult] = []

    /// On-device speech-to-text — Apple's SpeechAnalyzer (the app requires
    /// iOS 26, so it's always available). Only used for the fallback file
    /// re-transcription; live segmentation comes from the recorder.
    private var transcriber: any Transcribing { AppleSpeechTranscriber() }

    func requestPermissions() {}

    func reset() {
        stage = .idle
        redactedTranscript = ""
        transcriptTurns = []
        liveResults = []
    }

    func process(url: URL, rubric: Rubric, liveSegments: [String] = []) async {
        // Never auto-download the 4.3GB model mid-flow — the download runs from
        // Settings / launch auto-resume, never as a surprise inside Analyze.
        // Only the llama path needs it; Core AI's model ships in the app bundle.
        if LLMEngine.shared.requiresManagedDownload, !ModelDownloader.shared.isDownloaded {
            stage = .error("The AI model isn't downloaded yet. Open Settings (tap the gear) and download it, then try again.")
            return
        }

        // Keep the screen awake for the whole pipeline: auto-lock suspends the
        // app, and iOS halts our GPU (Metal) work with it — scoring would stall
        // mid-run. Restored no matter how processing exits.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        // Benchmark (dev-only): times this whole analysis when the toggle is on.
        // The label comes from the active backend, so a Core AI run stamps
        // itself correctly with no change here.
        BenchmarkRecorder.shared.begin(engine: LLMEngine.shared.label,
                                       criterionCount: rubric.criteria.count)

        // Keep the LLM RESIDENT across analyses. With Whisper + the diarizer
        // gone, the LLM is the only big model, so there's nothing to free it for
        // — and reloading a 4.3GB model on every analysis is exactly what made
        // the pipeline feel stuck ("Transcribing…"). The first analysis loads it
        // once; later ones reuse it.

        // 1) Get the utterances to attribute. PREFER the live transcript's own
        //    segmentation: Apple's streaming engine already cut it at natural
        //    pauses — which is where speakers change — so those are far better
        //    boundaries than re-transcribing the file into a flat blob and
        //    guessing sentence breaks (that flattening is what glued a doctor
        //    question onto the patient's answer). Fall back to re-transcribing
        //    the file only when there's no live transcript (e.g. live failed).
        //    (ORIGINAL behavior restored — a live-vs-file completeness check was
        //    tried here and backed out with the perf-regression batch.)
        stage = .transcribing
        BenchmarkRecorder.shared.markStage("transcribing")
        let liveUtterances = liveSegments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let utterances: [String]
        let flatTranscript: String
        if liveUtterances.count >= 2 {
            utterances = liveUtterances
            flatTranscript = liveUtterances.joined(separator: " ")
        } else {
            let fileResult = (try? await transcriber.transcribe(url: url))
                ?? TranscriptResult(text: "", segments: [])
            flatTranscript = fileResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            utterances = SpeakerAttribution.utterances(from: fileResult)
        }
        guard !flatTranscript.isEmpty else {
            stage = .error("No speech was captured. Try recording again, a bit closer to the mic.")
            BenchmarkRecorder.shared.end(success: false)
            return
        }

        // 2) Load the LLM (first analysis of the session only — it stays resident
        //    after). Loading a 4.3GB model takes a while, so show it as
        //    "Preparing AI model" instead of leaving the stuck-looking
        //    "Transcribing…" label up. The progress callback fires only for a
        //    first-run download.
        do {
            stage = .preparingModel(0)
            BenchmarkRecorder.shared.markStage("preparingModel")
            let loadStart = Date()
            try await LLMEngine.shared.ensureLoaded { fraction in
                self.stage = .preparingModel(fraction)
            }
            BenchmarkRecorder.shared.recordLoad(seconds: Date().timeIntervalSince(loadStart))

            // 3) Speaker separation WITHOUT diarization: split the transcript into
            //    utterances and have the LLM tag each Doctor/Patient, then merge
            //    consecutive same-role utterances into turns. Fixed utterance
            //    boundaries (the model only classifies) avoid the phase-slips that
            //    whole-transcript reconstruction produced.
            stage = .identifyingSpeakers
            BenchmarkRecorder.shared.markStage("attribution")
            var rawTurns: [TranscriptTurn]
            var twoSpeaker = false
            if utterances.count >= 4 {
                let raw = (try? await LLMEngine.shared.generate(
                    prompt: PromptBuilder.speakerAttributionPrompt(utterances: utterances),
                    maxTokens: utterances.count * 5 + 32)) ?? ""
                let roles = PromptBuilder.parseAttribution(raw, count: utterances.count)
                twoSpeaker = Set(roles.compactMap { $0 }).count >= 2
                rawTurns = twoSpeaker
                    ? SpeakerAttribution.turns(utterances: utterances, roles: roles)
                    : utterances.map { TranscriptTurn(speaker: "Speaker 1", text: $0) }
            } else {
                // Too short to be a conversation → one bubble, scored as the clinician.
                rawTurns = [TranscriptTurn(speaker: "Speaker 1", text: flatTranscript)]
            }

            // 4) Redact. Two speakers → the model sees Doctor:/Patient: labels and
            //    scores ONLY the Doctor. Solo → unlabeled text (the scoring prompt
            //    treats a single speaker as the clinician).
            stage = .redacting
            BenchmarkRecorder.shared.markStage("redacting")
            let scoringText = twoSpeaker
                ? rawTurns.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
                : flatTranscript
            redactedTranscript = PHIRedactor.redact(scoringText)
            transcriptTurns = rawTurns.map {
                TranscriptTurn(speaker: $0.speaker, text: PHIRedactor.redact($0.text))
            }

            // 5) Score each criterion against the doctor's communication.
            //    The shared prefix (instructions + transcript) is prefilled once
            //    and its KV state reused for all 16 criteria (prefix caching) —
            //    each call only processes the short question suffix.
            //    Publish each result as it lands so the UI fills in live.
            liveResults = []
            var results: [CriterionResult] = []
            var producedOutput = false   // guards the silent all-"missed" overflow case
            let total = rubric.criteria.count
            let sharedPrefix = PromptBuilder.scoringPrefix(transcript: redactedTranscript)
            BenchmarkRecorder.shared.markStage("scoring")
            for (index, criterion) in rubric.criteria.enumerated() {
                try Task.checkCancellation()   // Cancel button unwinds here between criteria
                stage = .scoring(done: index, total: total)
                let t0 = Date()

                // N/A gate: criteria that only apply in some encounters (e.g. the
                // physical-exam one) get a cheap yes/no check first — a "no" marks
                // them Not Applicable (gray) instead of scoring them as a miss.
                if criterion.responseType == "not_applicable_allowed" {
                    let gate = (try? await LLMEngine.shared.generate(
                        sharedPrefix: sharedPrefix,
                        suffix: PromptBuilder.applicabilityGateSuffix(criterion: criterion),
                        // 24, not 8: on the Core AI path Qwen3 spends ~5 tokens
                        // on an empty <think></think> block (even with
                        // /no_think) before the yes/no lands.
                        maxTokens: 24)) ?? ""
                    let g = gate.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    // Treat any clear "no / didn't happen" answer as Not Applicable.
                    let didNotHappen = (g.hasPrefix("no") || g.contains("no exam")
                        || g.contains("did not") || g.contains("didn't")
                        || g.contains("no physical") || g.contains("not take place"))
                        && !g.hasPrefix("yes")
                    print("[Scoring] \(criterion.id) gate=\"\(g)\" → \(didNotHappen ? "N/A" : "score")")
                    if didNotHappen {
                        let na = CriterionResult(criterionId: criterion.id, status: .notApplicable,
                                                 evidence: nil, comment: nil)
                        results.append(na); liveResults.append(na)
                        continue
                    }
                }

                let raw = try await LLMEngine.shared.generate(
                    sharedPrefix: sharedPrefix,
                    suffix: PromptBuilder.criterionSuffix(criterion: criterion),
                    maxTokens: 180)
                // Timing: criterion 0 pays the transcript prefill; 1+ should be
                // decode-only if prefix caching is working.
                print(String(format: "[Scoring] %@ took %.1fs", criterion.id, Date().timeIntervalSince(t0)))
                // Overflow guard: the shared prefix (transcript) is decoded once,
                // on the first real scoring call. If it produced NOTHING, the
                // transcript almost certainly overran the context window — fail
                // honestly instead of handing back an all-"missed" scorecard the
                // trainee would rightly distrust. (Later criteria reuse the same
                // cached prefix, so they share its fate; checking the first is enough.)
                if !producedOutput {
                    if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        stage = .error("This consultation was too long to analyse reliably on-device. Try recording a shorter session (under about 30 minutes).")
                        return
                    }
                    producedOutput = true
                }
                let result = FeedbackParser.parseCriterion(
                    raw: raw, criterionId: criterion.id, transcript: redactedTranscript,
                    allowsNA: criterion.responseType == "not_applicable_allowed")
                results.append(result)
                liveResults.append(result)
            }

            stage = .summarizing
            BenchmarkRecorder.shared.markStage("summarizing")
            let summary = try? await LLMEngine.shared.generate(
                prompt: PromptBuilder.summaryPrompt(rubric: rubric, results: results),
                maxTokens: 160)

            stage = .done(ConsultationFeedback(perCriterion: results, summary: summary))
            BenchmarkRecorder.shared.end(success: true)
        } catch is CancellationError {
            // User tapped Cancel — unwind quietly to idle (no error banner).
            stage = .idle
            BenchmarkRecorder.shared.end(success: false)
        } catch {
            // Full error, not just localizedDescription — the underlying type
            // and payload are what actually diagnose a generation failure.
            print("[Pipeline] analysis FAILED: \(String(describing: error))")
            stage = .error("Analysis failed: \(error.localizedDescription)")
            BenchmarkRecorder.shared.end(success: false)
        }
    }
}
