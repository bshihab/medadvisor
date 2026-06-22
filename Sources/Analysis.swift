import Foundation

/// Result for one rubric criterion, as returned by the model.
struct CriterionResult: Codable, Equatable, Identifiable {
    var id: String { criterionId }
    let criterionId: String
    let met: Bool
    let evidence: String?
    let comment: String?
}

/// The full feedback for one consultation.
struct ConsultationFeedback: Equatable {
    let perCriterion: [CriterionResult]
    let summary: String?
    let rawOutput: String   // kept so we can show something even if JSON parsing fails
}

/// Builds the scoring prompt from a rubric + the (redacted) transcript.
enum PromptBuilder {
    static func scoringPrompt(rubric: Rubric, transcript: String) -> String {
        let criteriaList = rubric.criteria.map { c -> String in
            var line = "- id=\(c.id): \(c.prompt)"
            if let good = c.whatGoodLooksLike { line += " (good looks like: \(good))" }
            if let req = c.requiredElements, !req.isEmpty {
                line += " (must address: \(req.joined(separator: "; ")))"
            }
            return line
        }.joined(separator: "\n")

        return """
        You are an experienced clinical communication tutor assessing a doctor's consultation.
        Evaluate the transcript against EACH rubric criterion below. For each one: decide if it \
        was met, quote the supporting line from the transcript as evidence, and give one short, \
        actionable improvement tip.

        Respond with ONLY valid JSON, no prose before or after, in EXACTLY this shape:
        {"criteria":[{"criterionId":"<id>","met":true,"evidence":"<quote>","comment":"<tip>"}],"summary":"<2-sentence overall>"}

        RUBRIC (encounter type: \(rubric.encounterType)):
        \(criteriaList)

        TRANSCRIPT:
        \(transcript)
        """
    }
}

/// Tolerant parser — small models wrap JSON in stray text, so we extract the
/// outermost JSON object and decode it; on failure we surface the raw output.
enum FeedbackParser {
    static func parse(raw: String) -> ConsultationFeedback {
        struct Wire: Codable { let criteria: [CriterionResult]; let summary: String? }
        if let json = extractJSONObject(raw),
           let data = json.data(using: .utf8),
           let wire = try? JSONDecoder().decode(Wire.self, from: data) {
            return ConsultationFeedback(perCriterion: wire.criteria, summary: wire.summary, rawOutput: raw)
        }
        return ConsultationFeedback(perCriterion: [], summary: nil, rawOutput: raw)
    }

    private static func extractJSONObject(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(s[start...end])
    }
}

/// Orchestrates the M2 pipeline: redact → build prompt → LLM → parse.
@MainActor
final class ConsultationAnalyzer: ObservableObject {
    enum State: Equatable {
        case idle
        case redacting
        case analyzing(String)   // partial output streamed from the model
        case done(ConsultationFeedback)
        case error(String)
    }

    @Published var state: State = .idle

    func reset() { state = .idle }

    func analyze(transcript: String, rubric: Rubric) async {
        state = .redacting
        let redacted = PHIRedactor.redact(transcript)
        let prompt = PromptBuilder.scoringPrompt(rubric: rubric, transcript: redacted)

        state = .analyzing("")
        do {
            let raw = try await LLMEngine.shared.generate(prompt: prompt, maxTokens: 900) { partial in
                self.state = .analyzing(partial)
            }
            state = .done(FeedbackParser.parse(raw: raw))
        } catch {
            state = .error("Analysis failed: \(error.localizedDescription)")
        }
    }
}
