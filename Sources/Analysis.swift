import Foundation

/// Result for one rubric criterion.
struct CriterionResult: Codable, Equatable, Identifiable {
    /// done = did it well (✓), partial = attempted, could improve (⚠️), missed = not done (✗)
    enum Status: String, Codable { case met, partial, missed }

    var id: String { criterionId }
    let criterionId: String
    let status: Status
    let evidence: String?
    let comment: String?

    init(criterionId: String, status: Status, evidence: String?, comment: String?) {
        self.criterionId = criterionId
        self.status = status
        self.evidence = evidence
        self.comment = comment
    }

    // Backward-compatible decode: older saved records used `met: Bool`.
    enum CodingKeys: String, CodingKey { case criterionId, status, evidence, comment, met }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        criterionId = try c.decode(String.self, forKey: .criterionId)
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence)
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
        if let s = try c.decodeIfPresent(Status.self, forKey: .status) {
            status = s
        } else if let met = try c.decodeIfPresent(Bool.self, forKey: .met) {
            status = met ? .met : .missed
        } else {
            status = .missed
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(criterionId, forKey: .criterionId)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(evidence, forKey: .evidence)
        try c.encodeIfPresent(comment, forKey: .comment)
    }
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
        You are a clinical communication tutor. In the transcript below, assess ONLY \
        the Doctor's communication — ignore the Patient's lines entirely. (If the \
        transcript has a single unlabeled speaker, treat that speaker as the clinician.)

        QUESTION: \(c.prompt)
        \(extras)
        Decide the result:
        - "done" = the clinician clearly did this well
        - "partial" = the clinician attempted it but it was incomplete or could be better
        - "missed" = the clinician did not do this at all

        Answer in EXACTLY three lines and nothing else:
        RESULT: done, partial, or missed
        EVIDENCE: a short quote from the transcript, or none
        TIP: one short, specific improvement tip

        TRANSCRIPT:
        \(transcript)
        """
    }

    /// Asks the LLM which speaker label is the doctor/clinician.
    static func doctorIdentificationPrompt(transcript: String) -> String {
        """
        Below is a medical consultation transcript with speakers labeled. Identify which \
        speaker is the doctor/clinician (the one taking the history, examining, explaining, \
        and giving the plan — not the patient).

        Reply with ONLY the speaker label and nothing else, for example: Speaker 1

        TRANSCRIPT:
        \(transcript)
        """
    }

    static func summaryPrompt(rubric: Rubric, results: [CriterionResult]) -> String {
        let met = results.filter { $0.status == .met }.count
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
        var status: CriterionResult.Status = .missed
        var evidence: String?
        var comment: String?

        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("result:") || lower.hasPrefix("met:") {
                if lower.contains("partial") {
                    status = .partial
                } else if lower.contains("done") || lower.contains("yes") {
                    status = .met
                } else if lower.contains("missed") || lower.contains("no") {
                    status = .missed
                }
            } else if lower.hasPrefix("evidence:") {
                evidence = String(line.dropFirst("evidence:".count)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("tip:") {
                comment = String(line.dropFirst("tip:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        // Strip surrounding quotes the model often adds (we add our own in the UI).
        if var e = evidence {
            e = e.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”"))
            evidence = (e.isEmpty || e.lowercased() == "none") ? nil : e
        }
        return CriterionResult(criterionId: criterionId, status: status, evidence: evidence, comment: comment)
    }
}

// The pipeline is orchestrated by EncounterProcessor (transcribe → diarize →
// redact → score), which reuses PromptBuilder and FeedbackParser above.
