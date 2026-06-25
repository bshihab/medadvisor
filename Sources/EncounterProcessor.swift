import Foundation

/// Orchestrates the on-device pipeline for one recording:
/// transcribe (WhisperKit) → diarize (FluidAudio) → conversation turns →
/// redact → score each criterion → summary.
///
/// Models are loaded ONE AT A TIME (Whisper, then diarizer, then LLM) and each
/// is released before the next to stay under the phone's memory ceiling.
@MainActor
final class EncounterProcessor: ObservableObject {
    enum Stage: Equatable {
        case idle
        case transcribing
        case identifyingSpeakers
        case redacting
        case scoring(done: Int, total: Int)
        case summarizing
        case done(ConsultationFeedback)
        case error(String)
    }

    @Published var stage: Stage = .idle
    @Published var redactedTranscript: String = ""
    /// Redacted, speaker-labeled turns for the chat view (empty if 1 speaker).
    @Published var transcriptTurns: [TranscriptTurn] = []

    private let whisper = WhisperTranscriber()
    private let diarizer = DiarizationService()

    func requestPermissions() {}

    func reset() {
        stage = .idle
        redactedTranscript = ""
        transcriptTurns = []
    }

    func process(liveTranscript: String, url: URL, rubric: Rubric) async {
        // Free any LLM still resident from a previous analysis BEFORE loading
        // Whisper/diarizer — only one big model should be in memory at a time.
        LLMEngine.shared.unload()

        // 1) Transcribe with WhisperKit (released on return).
        stage = .transcribing
        let whisperResult = (try? await whisper.transcribe(url: url))
            ?? WhisperResult(text: "", segments: [])
        var flatTranscript = whisperResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if flatTranscript.isEmpty {
            flatTranscript = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !flatTranscript.isEmpty else {
            stage = .error("No speech was captured. Try recording again, a bit closer to the mic.")
            return
        }

        // 2) Diarize and build conversation turns. We ALWAYS produce turns so the
        //    transcript is always a chat: one-sided if a single speaker, two-sided
        //    if diarization separated ≥2 voices.
        stage = .identifyingSpeakers
        var rawTurns: [TranscriptTurn] = []
        let speakers = (try? await diarizer.diarize(url: url)) ?? []

        if !whisperResult.segments.isEmpty {
            if SpeakerMerger.distinctSpeakerCount(speakers) >= 2 {
                rawTurns = SpeakerMerger.turns(segments: whisperResult.segments, speakers: speakers)
                // Two speakers → label the transcript the model sees.
                flatTranscript = rawTurns.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
            } else {
                // One speaker → one bubble per Whisper segment, all on one side.
                rawTurns = whisperResult.segments.map {
                    TranscriptTurn(speaker: "Speaker 1", text: $0.text)
                }
            }
        }
        // Last resort (e.g. fell back to the live transcript with no segments):
        // still show a single bubble rather than a plain block.
        if rawTurns.isEmpty {
            rawTurns = [TranscriptTurn(speaker: "Speaker 1", text: flatTranscript)]
        }

        // 3) Redact (for the LLM and for storage/display).
        stage = .redacting
        redactedTranscript = PHIRedactor.redact(flatTranscript)
        transcriptTurns = rawTurns.map {
            TranscriptTurn(speaker: $0.speaker, text: PHIRedactor.redact($0.text))
        }

        // 4) Score each criterion (LLM loads here, after the others are freed).
        do {
            var results: [CriterionResult] = []
            let total = rubric.criteria.count
            for (index, criterion) in rubric.criteria.enumerated() {
                stage = .scoring(done: index, total: total)
                let raw = try await LLMEngine.shared.generate(
                    prompt: PromptBuilder.criterionPrompt(criterion: criterion, transcript: redactedTranscript),
                    maxTokens: 180)
                results.append(FeedbackParser.parseCriterion(raw: raw, criterionId: criterion.id))
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
