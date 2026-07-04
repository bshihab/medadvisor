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
    /// Shared scoring prefix — identical for all 16 criteria, so the LLM's KV
    /// state for it (including the expensive transcript) is computed once and
    /// reused via prefix caching. The per-criterion QUESTION goes in the suffix.
    static func scoringPrefix(transcript: String) -> String {
        """
        You are a STRICT clinical communication examiner. Below is the transcript of a \
        medical consultation. You will then be asked ONE question about the Doctor's \
        communication — assess ONLY the Doctor, ignore the Patient's lines entirely. \
        (If the transcript has a single unlabeled speaker, treat that speaker as the clinician.)

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
        EVIDENCE: a direct quote of the Doctor's words (write none if missed)
        TIP: one short, specific improvement tip if partial or missed (write none if done)

        TRANSCRIPT:
        \(transcript)
        """
    }

    /// Short per-criterion suffix appended after the cached prefix.
    static func criterionSuffix(criterion c: Criterion) -> String {
        var extras = ""
        if let good = c.whatGoodLooksLike { extras += "Good looks like: \(good)\n" }
        if let req = c.requiredElements, !req.isEmpty {
            extras += "Must address: \(req.joined(separator: "; "))\n"
        }
        return """


        QUESTION: \(c.prompt)
        \(extras)
        Answer now in the exact three-line format.
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
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // Result: the first line that clearly states a verdict — robust to models
        // that DROP the RESULT: label or add markdown (a bare "done", "**done**",
        // "1. done"). Qwen and others don't follow the exact format, and requiring
        // the label silently zeroed them out (everything read as missed).
        var status: CriterionResult.Status = .missed
        var resultIndex: Int?
        for (i, line) in lines.enumerated() {
            if let kw = keyword(clean(line)) {
                status = kw
                resultIndex = i
                break
            }
        }
        if resultIndex == nil {   // last resort: search anywhere
            let low = raw.lowercased()
            if low.contains("partial") { status = .partial }
            else if low.contains("missed") || low.contains("not done") { status = .missed }
            else if low.contains("done") || low.contains("yes") { status = .met }
        }

        // Evidence: an EVIDENCE: line if present, else the text between the result
        // line and the TIP line (models that drop labels put the quote there).
        var evidence: String?
        var comment: String?
        for line in lines {
            let c = clean(line).lowercased()
            if c.hasPrefix("evidence") { evidence = value(after: line) }
            else if c.hasPrefix("tip") { comment = value(after: line) }
        }
        if evidence == nil, let idx = resultIndex, idx + 1 < lines.count {
            // Take only the FIRST plausible line after the verdict — joining
            // everything up to TIP glued stray verdict/none/tip words into the
            // quote when the model mashed its lines together.
            for line in lines[(idx + 1)...] {
                let c = clean(line)
                let low = c.lowercased()
                if low.hasPrefix("tip") { break }
                if keyword(c) != nil || low == "none" || c.isEmpty { continue }
                evidence = c.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”"))
                break
            }
        }
        if var e = evidence {
            e = e.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”"))
            evidence = (e.isEmpty || e.lowercased() == "none") ? nil : e
        }
        if let c = comment, c.lowercased() == "none" || c.isEmpty {
            comment = nil
        }

        // Guardrail against over-scoring: a "met" MUST be backed by a quote that
        // actually appears in the transcript. No/hallucinated evidence → missed.
        if status == .met, !isSupported(evidence, by: transcript) {
            status = .missed
        }

        return CriterionResult(criterionId: criterionId, status: status, evidence: evidence, comment: comment)
    }

    /// Strip markdown, list markers, and a leading label so we can read the value.
    private static func clean(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: "^[*\\-•>#\\s]+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^\\d+[.)]\\s*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        let low = s.lowercased()
        for pfx in ["result:", "met:", "verdict:", "answer:", "score:"] where low.hasPrefix(pfx) {
            return String(s.dropFirst(pfx.count)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// Map a cleaned line to a status if it clearly states one.
    /// Order matters: check missed/not-done BEFORE done.
    private static func keyword(_ s: String) -> CriterionResult.Status? {
        let low = s.lowercased()
        if low.hasPrefix("partial") { return .partial }
        if low.hasPrefix("missed") || low.hasPrefix("not done") || low == "no" || low == "no." { return .missed }
        if low.hasPrefix("done") || low.hasPrefix("met") || low == "yes" || low == "yes." { return .met }
        return nil
    }

    private static func value(after line: String) -> String? {
        guard let idx = line.firstIndex(of: ":") else { return nil }
        let v = String(line[line.index(after: idx)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”"))
        return v.isEmpty ? nil : v
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
