import Foundation

/// Result for one rubric criterion.
struct CriterionResult: Codable, Equatable, Identifiable {
    var id: String { criterionId }
    let criterionId: String
    let met: Bool
    let evidence: String?
    let comment: String?
}

/// The full feedback for one consultation.
struct ConsultationFeedback: Equatable, Codable {
    let perCriterion: [CriterionResult]
    let summary: String?
}

/// Prompts. We score ONE criterion per call — small on-device models are far
/// more reliable answering a single narrow question than filling a big schema.
enum PromptBuilder {
    static func criterionPrompt(criterion c: Criterion, transcript: String) -> String {
        var extras = ""
        if let good = c.whatGoodLooksLike { extras += "Good looks like: \(good)\n" }
        if let req = c.requiredElements, !req.isEmpty {
            extras += "Must address: \(req.joined(separator: "; "))\n"
        }
        return """
        You are a clinical communication tutor. The transcript below is a single \
        unlabeled stream — infer who the clinician is and assess ONLY the clinician.

        QUESTION: \(c.prompt)
        \(extras)
        Answer in EXACTLY three lines and nothing else:
        MET: yes or no
        EVIDENCE: a short quote from the transcript, or none
        TIP: one short, specific improvement tip

        TRANSCRIPT:
        \(transcript)
        """
    }

    static func summaryPrompt(rubric: Rubric, results: [CriterionResult]) -> String {
        let met = results.filter { $0.met }.count
        return """
        A doctor met \(met) of \(results.count) criteria in a \(rubric.encounterType) consultation. \
        In 2 sentences, summarize how they did overall and the single most important thing to \
        improve next time. Plain prose, no lists.
        """
    }
}

/// Tolerant line parser for the 3-line per-criterion answer.
enum FeedbackParser {
    static func parseCriterion(raw: String, criterionId: String) -> CriterionResult {
        var met = false
        var evidence: String?
        var comment: String?

        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("met:") {
                met = lower.contains("yes")
            } else if lower.hasPrefix("evidence:") {
                evidence = String(line.dropFirst("evidence:".count)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("tip:") {
                comment = String(line.dropFirst("tip:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if let e = evidence, e.isEmpty || e.lowercased() == "none" { evidence = nil }
        return CriterionResult(criterionId: criterionId, met: met, evidence: evidence, comment: comment)
    }
}

/// Orchestrates the pipeline: redact → score each criterion → summary.
@MainActor
final class ConsultationAnalyzer: ObservableObject {
    enum State: Equatable {
        case idle
        case redacting
        case scoring(done: Int, total: Int)
        case summarizing
        case done(ConsultationFeedback)
        case error(String)
    }

    @Published var state: State = .idle

    func reset() { state = .idle }

    func analyze(transcript: String, rubric: Rubric) async {
        state = .redacting
        let redacted = PHIRedactor.redact(transcript)

        var results: [CriterionResult] = []
        let total = rubric.criteria.count
        for (index, criterion) in rubric.criteria.enumerated() {
            state = .scoring(done: index, total: total)
            let prompt = PromptBuilder.criterionPrompt(criterion: criterion, transcript: redacted)
            do {
                let raw = try await LLMEngine.shared.generate(prompt: prompt, maxTokens: 180)
                results.append(FeedbackParser.parseCriterion(raw: raw, criterionId: criterion.id))
            } catch {
                state = .error("Analysis failed: \(error.localizedDescription)")
                return
            }
        }

        state = .summarizing
        let summary = try? await LLMEngine.shared.generate(
            prompt: PromptBuilder.summaryPrompt(rubric: rubric, results: results),
            maxTokens: 160
        )

        state = .done(ConsultationFeedback(perCriterion: results, summary: summary))
    }
}
