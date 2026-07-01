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
        You are a STRICT clinical communication examiner. In the transcript below, assess ONLY \
        the Doctor's communication — ignore the Patient's lines entirely. (If the \
        transcript has a single unlabeled speaker, treat that speaker as the clinician.)

        QUESTION: \(c.prompt)
        \(extras)
        Scoring rules — follow exactly:
        - Judge ONLY what the Doctor ACTUALLY said in the transcript. Never reward \
        intentions, assumptions, or things that "could have" been said.
        - "done" REQUIRES a direct supporting quote from the Doctor. If you cannot quote \
        the Doctor actually doing this, it is NOT done.
        - If the Doctor did not clearly do this, answer "missed".
        - If the transcript is empty, very short, or has no relevant Doctor communication, \
        answer "missed".

        Result:
        - "done" = the Doctor clearly did this, and you can quote it
        - "partial" = the Doctor attempted it but it was incomplete
        - "missed" = the Doctor did not do this (or there is no evidence they did)

        Answer in EXACTLY three lines and nothing else:
        RESULT: done, partial, or missed
        EVIDENCE: a direct quote of the Doctor's words, or the word none
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
    static func parseCriterion(raw: String, criterionId: String, transcript: String) -> CriterionResult {
        var status: CriterionResult.Status = .missed
        var evidence: String?
        var comment: String?

        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("result:") || lower.hasPrefix("met:") {
                // Order matters: check "missed"/"not done" BEFORE "done" so a
                // phrase like "not done" isn't misread as met.
                if lower.contains("partial") {
                    status = .partial
                } else if lower.contains("missed") || lower.contains("not done")
                            || lower.contains(" no") || lower.hasSuffix("no") {
                    status = .missed
                } else if lower.contains("done") || lower.contains("yes") {
                    status = .met
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

        // Guardrail against small-model over-scoring: a "met" MUST be backed by a
        // quote that actually appears in the transcript. No/hallucinated evidence
        // → downgrade to missed. (This is what fixes "said nothing → 9/16 met".)
        if status == .met, !isSupported(evidence, by: transcript) {
            status = .missed
        }

        return CriterionResult(criterionId: criterionId, status: status, evidence: evidence, comment: comment)
    }

    /// True only if the evidence quote is genuinely grounded in the transcript:
    /// a normalized substring match, or at least one substantive word (≥4 chars)
    /// shared with the transcript. Empty/none/hallucinated quotes return false.
    private static func isSupported(_ evidence: String?, by transcript: String) -> Bool {
        guard let evidence, !evidence.isEmpty else { return false }
        let t = normalize(transcript)
        let e = normalize(evidence)
        guard !e.isEmpty else { return false }
        if t.range(of: e) != nil { return true }
        let transcriptWords = Set(t.split(separator: " ").map(String.init))
        let evidenceWords = e.split(separator: " ").map(String.init)
        let contentWords = evidenceWords.filter { $0.count >= 4 }
        if contentWords.isEmpty {
            // Very short quote — accept if any of its words appears verbatim.
            return evidenceWords.contains { transcriptWords.contains($0) }
        }
        return contentWords.contains { transcriptWords.contains($0) }
    }

    /// Lowercase, keep only alphanumerics + spaces, collapse whitespace.
    private static func normalize(_ s: String) -> String {
        let mapped = s.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : " "
        }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }
}

// The pipeline is orchestrated by EncounterProcessor (transcribe → diarize →
// redact → score), which reuses PromptBuilder and FeedbackParser above.
