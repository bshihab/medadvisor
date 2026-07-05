import Foundation

/// Result for one rubric criterion.
struct CriterionResult: Codable, Equatable, Identifiable {
    /// done = did it well (✓), partial = attempted (⚠️), missed = not done (✗),
    /// notApplicable = this criterion didn't apply to the encounter (–, gray;
    /// e.g. no physical exam took place). N/A is excluded from the score.
    enum Status: String, Codable { case met, partial, missed, notApplicable }

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
        medical consultation between a clinician and a patient. The speaker labels come \
        from automatic transcription and are SOMETIMES WRONG — a line labelled "Patient:" \
        may actually be the clinician, and vice versa. Decide who is speaking from the \
        CONTENT, not just the label: the clinician greets, takes the history, asks the \
        questions, examines, explains, reassures, and gives the plan; the patient \
        describes their own symptoms, feelings, and worries. (If there is a single \
        unlabelled speaker, treat that speaker as the clinician.)

        You will then be asked ONE question about the CLINICIAN's communication.

        Scoring rules — follow exactly:
        - Judge whether the CLINICIAN actually demonstrated this, based on what was said \
        anywhere in the transcript — NOT on the possibly-wrong speaker label.
        - NEVER credit the clinician for something the PATIENT said. A patient describing \
        their own symptoms or feelings is not the clinician exploring them.
        - The quote must ACTUALLY demonstrate the SPECIFIC behavior being asked about. A \
        generic greeting, acknowledgement, or sign-off ("take care", "I've got other \
        patients", "okay", "goodbye") does NOT count as safety-netting, teach-back, \
        exploring concerns, or inviting questions. If the quote does not clearly show \
        THIS exact behavior, answer "missed".
        - "done" REQUIRES a direct supporting quote of the clinician actually doing it. If \
        you cannot quote it, it is NOT done. Never reward intentions or things that \
        "could have" been said.
        - If the clinician did not clearly do this, answer "missed".
        - If the transcript is empty or very short, answer "missed".

        Result:
        - "done" = the clinician clearly did this, and you can quote it
        - "partial" = the clinician attempted it but it was incomplete
        - "missed" = the clinician did not do this (or there is no evidence they did)

        Answer in EXACTLY three lines and nothing else:
        RESULT: done, partial, or missed
        EVIDENCE: a short direct quote of the clinician's OWN words, with NO speaker labels (write none if missed)
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

    /// Yes/no gate for criteria that only apply in some encounters (N/A-allowed).
    /// Reuses the cached transcript prefix. A "no" → the criterion is N/A and is
    /// not scored (so e.g. an absent physical exam isn't marked as a failure).
    static func applicabilityGateSuffix(criterion c: Criterion) -> String {
        """


        Answer ONE factual question about the transcript above — ignore how well \
        anything was done.

        Did a physical examination of the patient actually take place in this \
        consultation — for example checking the pulse or blood pressure, listening to \
        the chest, feeling the neck or abdomen, or looking in the eyes or ears?

        Reply with ONLY one word: "yes" if an examination clearly happened, or "no" if \
        no examination took place.
        """
    }

    /// Speaker attribution WITHOUT diarization: give the LLM the numbered
    /// utterances (in order) and have it tag each Doctor/Patient. Fixed
    /// boundaries (the model only classifies, never guesses where turns break)
    /// avoid the phase-slips that whole-transcript reconstruction produced.
    /// Output is tiny ("1: D\n2: P…"), so it's fast on the already-loaded LLM.
    static func speakerAttributionPrompt(utterances: [String]) -> String {
        let numbered = utterances.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        return """
        These are numbered utterances from a two-person doctor–patient consultation, \
        in chronological order. Label EVERY utterance as D (Doctor) or P (Patient).

        Decide each one from its CONTENT and clinical role — do NOT just assume the \
        speakers take strict turns:
        - The DOCTOR opens by greeting and introducing themselves, then asks the \
        history questions, proposes and narrates the exam, explains findings, \
        reassures, and gives the plan and safety-net.
        - The PATIENT describes their own symptoms, feelings, worries, and answers \
        questions about themselves.
        - Speakers do NOT alternate every line. A greeting, a multi-part question, or \
        a follow-up is usually the SAME speaker as the line before it — one speaker \
        often has several utterances in a row.
        - Assign short lines ("Okay.", "Right.", "Yeah, that's fine.") to whoever the \
        surrounding content shows is speaking.

        Output ONLY one line per number in the form "N: D" or "N: P". Nothing else.

        UTTERANCES:
        \(numbered)
        """
    }

    /// Parses the attribution reply ("1: D", "2: P", …) into a role per
    /// utterance, aligned to `count`. Missing/garbled lines stay nil (the merger
    /// inherits the previous speaker). Returns Doctor/Patient strings.
    static func parseAttribution(_ raw: String, count: Int) -> [String?] {
        var roles = [String?](repeating: nil, count: count)
        for line in raw.split(whereSeparator: \.isNewline) {
            // Match "<n> : <D|P>" allowing markdown/punctuation around them.
            guard let numMatch = line.range(of: "\\d+", options: .regularExpression),
                  let n = Int(line[numMatch]), n >= 1, n <= count else { continue }
            let rest = line[numMatch.upperBound...].lowercased()
            if rest.contains("p") && !rest.contains("d") { roles[n - 1] = "Patient" }
            else if rest.contains("d") && !rest.contains("p") { roles[n - 1] = "Doctor" }
            else if let d = rest.firstIndex(of: "d"), let p = rest.firstIndex(of: "p") {
                roles[n - 1] = d < p ? "Doctor" : "Patient"
            }
        }
        return roles
    }

    static func summaryPrompt(rubric: Rubric, results: [CriterionResult]) -> String {
        let met = results.filter { $0.status == .met }.count
        // N/A criteria (e.g. no exam) aren't part of the denominator.
        let applicable = results.filter { $0.status != .notApplicable }.count
        return """
        A doctor met \(met) of \(applicable) criteria in a \(rubric.encounterType) consultation. \
        In 2 sentences, summarize how they did overall and the single most important thing to \
        improve next time. Plain prose, no lists.
        """
    }
}

/// Tolerant line parser for the 3-line per-criterion answer.
enum FeedbackParser {
    static func parseCriterion(raw: String, criterionId: String, transcript: String,
                               allowsNA: Bool = false) -> CriterionResult {
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
            if low.contains("n/a") || low.contains("not applicable") { status = .notApplicable }
            else if low.contains("partial") { status = .partial }
            else if low.contains("missed") || low.contains("not done") { status = .missed }
            else if low.contains("done") || low.contains("yes") { status = .met }
        }

        // N/A is only honored for criteria that allow it; otherwise it's a miss.
        if status == .notApplicable, !allowsNA { status = .missed }

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
            e = stripSpeakerLabels(e).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”"))
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

    /// Remove any "Doctor:" / "Patient:" / "Speaker N:" labels from an evidence
    /// quote so it reads as clean prose (attribution can mislabel a boundary and
    /// the model sometimes echoes the labels into the quote), then tidy spacing.
    private static func stripSpeakerLabels(_ s: String) -> String {
        var out = s.replacingOccurrences(
            of: "(?i)\\b(doctor|patient|clinician|speaker\\s*\\d+)\\s*:\\s*",
            with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
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
    /// Order matters: check n/a and missed/not-done BEFORE done.
    private static func keyword(_ s: String) -> CriterionResult.Status? {
        let low = s.lowercased()
        if low.hasPrefix("n/a") || low.hasPrefix("not applicable") || low == "na" { return .notApplicable }
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

// The pipeline is orchestrated by EncounterProcessor (transcribe → LLM speaker
// attribution → redact → score), which reuses PromptBuilder and FeedbackParser.
