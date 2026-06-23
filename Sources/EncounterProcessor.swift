import Foundation

/// Orchestrates the full on-device pipeline for one recording:
/// transcribe → diarize → merge into a speaker-labeled transcript → redact →
/// score each criterion → summary.
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
    @Published var labeledTranscript: String = ""
    /// Redacted version (what we persist + show in history).
    @Published var redactedTranscript: String = ""

    private let transcriber = SpeechTranscriber()
    private let diarizer = DiarizationService()

    func requestPermissions() { transcriber.requestPermission() }

    func reset() {
        stage = .idle
        labeledTranscript = ""
        redactedTranscript = ""
    }

    func process(url: URL, rubric: Rubric) async {
        do {
            stage = .transcribing
            let transcription = try await transcriber.transcribe(url: url)

            stage = .identifyingSpeakers
            var transcript = transcription.text
            // Only apply speaker labels when diarization genuinely separated ≥2
            // speakers AND we have usable word timings. Otherwise a collapsed
            // "all Speaker 1" labeling would confuse the model and tank the score,
            // so we fall back to the clean transcript and let it infer roles.
            if let segments = try? await diarizer.diarize(url: url) {
                let distinctSpeakers = Set(segments.map { $0.speakerId }).count
                let timingsUsable = transcription.words.contains { $0.start > 0 }
                if distinctSpeakers >= 2 && timingsUsable {
                    transcript = TranscriptMerger.labeled(words: transcription.words, segments: segments)
                }
            }
            labeledTranscript = transcript

            stage = .redacting
            let redacted = PHIRedactor.redact(transcript)
            redactedTranscript = redacted

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
            stage = .error(error.localizedDescription)
        }
    }
}
