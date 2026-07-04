import Foundation

/// Orchestrates the on-device pipeline for one recording:
/// transcribe (Apple/Whisper) → LLM speaker attribution → conversation turns →
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

    /// Picks the speech engine at runtime so we can A/B without rebuilding.
    /// Selection lives in Settings ("transcriptionEngine").
    private var transcriber: any Transcribing {
        switch TranscriptionEngine.current {
        case .apple:
            if #available(iOS 26.0, *) { return AppleSpeechTranscriber() }
            return WhisperTranscriber()   // fallback below iOS 26
        case .whisper:
            return WhisperTranscriber()
        }
    }

    func requestPermissions() {}

    func reset() {
        stage = .idle
        redactedTranscript = ""
        transcriptTurns = []
        liveResults = []
    }

    func process(url: URL, rubric: Rubric) async {
        // Free any LLM still resident from a previous analysis BEFORE the
        // transcriber loads — only one big model should be in memory at a time.
        LLMEngine.shared.unload()

        // 1) Transcribe the whole file (Apple SpeechAnalyzer or WhisperKit,
        //    whichever is selected; released on return).
        stage = .transcribing
        let whisperResult = (try? await transcriber.transcribe(url: url))
            ?? TranscriptResult(text: "", segments: [])
        let flatTranscript = whisperResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flatTranscript.isEmpty else {
            stage = .error("No speech was captured. Try recording again, a bit closer to the mic.")
            return
        }

        // 2) Load the LLM once (the transcriber is freed by now; first run
        //    downloads ~4.3GB). The same model does speaker attribution + scoring.
        do {
            try await LLMEngine.shared.ensureLoaded { fraction in
                self.stage = .preparingModel(fraction)
            }

            // 3) Speaker separation WITHOUT diarization: split the transcript into
            //    utterances and have the LLM tag each Doctor/Patient, then merge
            //    consecutive same-role utterances into turns. Fixed utterance
            //    boundaries (the model only classifies) avoid the phase-slips that
            //    whole-transcript reconstruction produced.
            stage = .identifyingSpeakers
            let utterances = SpeakerAttribution.utterances(from: whisperResult)
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
            let total = rubric.criteria.count
            let sharedPrefix = PromptBuilder.scoringPrefix(transcript: redactedTranscript)
            for (index, criterion) in rubric.criteria.enumerated() {
                stage = .scoring(done: index, total: total)
                let t0 = Date()
                let raw = try await LLMEngine.shared.generate(
                    sharedPrefix: sharedPrefix,
                    suffix: PromptBuilder.criterionSuffix(criterion: criterion),
                    maxTokens: 180)
                // Timing: criterion 0 pays the transcript prefill; 1+ should be
                // decode-only if prefix caching is working.
                print(String(format: "[Scoring] %@ took %.1fs", criterion.id, Date().timeIntervalSince(t0)))
                let result = FeedbackParser.parseCriterion(
                    raw: raw, criterionId: criterion.id, transcript: redactedTranscript,
                    allowsNA: criterion.responseType == "not_applicable_allowed")
                results.append(result)
                liveResults.append(result)
            }

            stage = .summarizing
            let summary = try? await LLMEngine.shared.generate(
                prompt: PromptBuilder.summaryPrompt(rubric: rubric, results: results),
                maxTokens: 160)

            stage = .done(ConsultationFeedback(perCriterion: results, summary: summary))
        } catch {
            stage = .error("Analysis failed: \(error.localizedDescription)")
        }
    }
}
