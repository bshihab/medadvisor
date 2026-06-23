import Foundation

/// Orchestrates the on-device pipeline for one recording:
/// use the live transcript → redact → score each criterion → summary.
///
/// We use the LIVE transcript (captured during recording) as the source of
/// truth — the separate file-based pass proved unreliable on the engine-written
/// audio. Diarization/speaker labels are parked until we have reliable word
/// timings + voice enrollment; the model infers roles from the transcript.
@MainActor
final class EncounterProcessor: ObservableObject {
    enum Stage: Equatable {
        case idle
        case transcribing
        case redacting
        case scoring(done: Int, total: Int)
        case summarizing
        case done(ConsultationFeedback)
        case error(String)
    }

    @Published var stage: Stage = .idle
    @Published var labeledTranscript: String = ""
    @Published var redactedTranscript: String = ""

    private let transcriber = SpeechTranscriber()

    func requestPermissions() { transcriber.requestPermission() }

    func reset() {
        stage = .idle
        labeledTranscript = ""
        redactedTranscript = ""
    }

    func process(liveTranscript: String, url: URL, rubric: Rubric) async {
        var transcript = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fallback to a file-based pass only if the live transcript came back empty.
        if transcript.isEmpty {
            stage = .transcribing
            transcript = ((try? await transcriber.transcribe(url: url))?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !transcript.isEmpty else {
            stage = .error("No speech was captured. Try recording again, a bit closer to the mic.")
            return
        }

        labeledTranscript = transcript

        stage = .redacting
        let redacted = PHIRedactor.redact(transcript)
        redactedTranscript = redacted

        do {
            var results: [CriterionResult] = []
            let total = rubric.criteria.count
            for (index, criterion) in rubric.criteria.enumerated() {
                stage = .scoring(done: index, total: total)
                let raw = try await LLMEngine.shared.generate(
                    prompt: PromptBuilder.criterionPrompt(criterion: criterion, transcript: redacted),
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
