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

    /// Draft rubrics carry author placeholders like "[Director to specify …]".
    /// Those must NEVER reach the model as scoring guidance (they skew the very
    /// criterion the director hasn't filled in yet). Treat bracketed / TBD text
    /// as absent.
    static func isPlaceholder(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.hasPrefix("[") && t.hasSuffix("]") { return true }
        let low = t.lowercased()
        return low.contains("to specify") || low.contains("tbd") || low.contains("director to")
    }

    /// Short per-criterion suffix appended after the cached prefix.
    static func criterionSuffix(criterion c: Criterion) -> String {
        var extras = ""
        if let good = c.whatGoodLooksLike, !isPlaceholder(good) {
            extras += "Good looks like: \(good)\n"
        }
        if let req = c.requiredElements?.filter({ !isPlaceholder($0) }), !req.isEmpty {
            extras += "Must address: \(req.joined(separator: "; "))\n"
        }
        return """


        QUESTION: \(c.prompt)
        \(extras)
        Answer now in the exact three-line format.
        """
    }

    /// Second-pass verification of "done" verdicts (shipped 2026-09-03).
    ///
    /// Every model measured on this task fails toward leniency: it finds *a*
    /// real quote and credits it against a criterion the quote does not show
    /// (a prescription line offered as "avoided interrupting"). The fix that
    /// won the bake-off is not new weights but a second call: show the model
    /// its own quote and ask one sceptical question — CONFIRM or REJECT.
    /// Measured against blind human grading of realistic consultations:
    /// single pass 65.1% agreement → with this pass (scoped) 84.1%, at the
    /// human inter-rater band (85.7%). A fine-tune scored 74.6% alone and
    /// 79.4% with this pass — the trick beats the training (FINDINGS.md in
    /// tools/llm-benchmark/calibration).
    ///
    /// Split prefix/suffix like scoring so all verify calls in a consultation
    /// share ONE cached prefill of the transcript. Byte-identical when
    /// concatenated to the measured VERIFY_PROMPT in app_scoring.py.
    static func verifyPrefix(transcript: String) -> String {
        """
        A grader reviewed the consultation below and judged ONE criterion as "done". \
        Check that judgment strictly — your job is to catch a quote that does not actually \
        show the specific behavior being asked about.

        TRANSCRIPT:
        \(transcript)
        """
    }

    static func verifySuffix(criterion c: Criterion, evidence: String?) -> String {
        var extras = ""
        if let good = c.whatGoodLooksLike, !isPlaceholder(good) {
            extras += "Good looks like: \(good)\n"
        }
        if let req = c.requiredElements?.filter({ !isPlaceholder($0) }), !req.isEmpty {
            extras += "Must address: \(req.joined(separator: "; "))\n"
        }
        return """


        CRITERION: \(c.prompt)
        \(extras)
        THE GRADER'S EVIDENCE: "\(evidence ?? "")"

        Does that quote, spoken by the CLINICIAN, actually demonstrate THIS SPECIFIC criterion?
        - A generic greeting, pleasantry, acknowledgement or sign-off ("take care", "okay", \
        "right", "no problem") does NOT demonstrate a specific behavior.
        - A quote showing a DIFFERENT behavior than the one asked about does NOT count, even \
        if it is good practice.
        - Something the PATIENT said never counts, whatever the speaker label claims.
        - If the quote genuinely shows this exact behavior, CONFIRM it — do not reject a \
        correct judgment.

        Reply with ONE word: CONFIRM or REJECT.
        """
    }

    /// Yes/no gate for criteria that only apply in some encounters (N/A-allowed).
    /// Reuses the cached transcript prefix. A "no" → the criterion is N/A and is
    /// not scored. The question is PER-CRITERION: it used to be hardwired to
    /// "did a physical exam happen?", which mis-gated other N/A criteria (e.g.
    /// inpatient "include the family" was N/A'd on whether an exam occurred).
    static func applicabilityGateSuffix(criterion c: Criterion) -> String {
        let question = c.applicabilityQuestion
            ?? "Considering only the transcript, did the situation this asks about — “\(c.prompt)” — actually arise in this consultation, so it could be assessed at all?"
        return """


        Answer ONE factual question about the transcript above — ignore how well \
        anything was done.

        \(question)

        Reply with ONLY one word: "yes" if it applied to this consultation, or "no" if \
        it did not apply.
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

        Strong signals — a line is almost certainly the DOCTOR if it contains phrasing \
        such as: "what brought you in", "what brings you in", "how can I help", "tell me \
        more about", "when did it start", "how long have you", "any fever", "have you \
        tried", "have you noticed", "let me examine", "let me take a look", "open wide", \
        "I'll check your", "feel your neck", "in plain terms", "here's what I'd suggest", \
        "I'd recommend", "come back or call us", "before we finish", "what questions do \
        you have", "could you tell me back", "thank you for telling me". \
        A line is almost certainly the PATIENT if it is a first-person account of \
        symptoms or feelings — e.g. "I've been feeling", "I've had", "it started", "I'm \
        worried", "I got scared", "I googled it".

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

    /// The closing summary shown under the scorecard.
    ///
    /// This used to pass ONLY counts — "met 12 of 16" — and then ask for "the
    /// single most important thing to improve next time". The model was never
    /// told WHICH behaviours were missed, so that advice could only be guessed.
    /// It reliably produced plausible, generic coaching that had no connection to
    /// the consultation, which is worse than no summary: a trainee has no way to
    /// tell invented advice from graded advice.
    ///
    /// Now the actual gaps go in. Missed first (they are the real failures),
    /// then partials, capped at 6 so the summary prompt stays small next to the
    /// cached transcript prefix.
    static func summaryPrompt(rubric: Rubric, results: [CriterionResult]) -> String {
        let met = results.filter { $0.status == .met }.count
        // N/A criteria (e.g. no exam) aren't part of the denominator.
        let applicable = results.filter { $0.status != .notApplicable }.count
        let naCount = results.filter { $0.status == .notApplicable }.count
        // encounterType is Optional — interpolating it raw put a literal
        // `Optional("…")` into the prompt (and "nil" when absent).
        let encounter = rubric.encounterType ?? "clinical"

        let promptOf = Dictionary(rubric.criteria.map { ($0.id, $0.prompt) },
                                  uniquingKeysWith: { a, _ in a })
        func labels(_ status: CriterionResult.Status) -> [String] {
            results.filter { $0.status == status }
                .compactMap { promptOf[$0.criterionId]?.trimmingCharacters(in: CharacterSet(charactersIn: "?")) }
        }
        let gaps = (labels(.missed) + labels(.partial)).prefix(6)

        let gapBlock = gaps.isEmpty
            ? "They met every applicable criterion."
            : "Behaviours they did NOT do (or only partly did):\n"
              + gaps.map { "- \($0)" }.joined(separator: "\n")

        // State N/A explicitly. The denominator silently shrinks when a criterion
        // does not apply (12/16 becomes 12/15), so without this the summary can
        // describe a score the trainee cannot reconcile with the scorecard.
        let naNote = naCount > 0
            ? "\n\(naCount) criterion did not apply to this consultation and was not scored."
            : ""

        return """
        A doctor met \(met) of \(applicable) criteria in a \(encounter) consultation.\(naNote)

        \(gapBlock)

        In 2 sentences, summarize how they did overall and the single most important thing to \
        improve next time. Base the improvement on the list above — do not invent a gap that is \
        not listed. Plain prose, no lists.
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

    /// True when the verifier rejects the grader's "done". Defaults to KEEPING
    /// the verdict on unparseable output — a garbled reply must not silently
    /// destroy recall (the reject-everything failure is how Gemma-3 died).
    static func verificationRejects(_ reply: String) -> Bool {
        let low = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if low.hasPrefix("reject") || low.hasPrefix("no") { return true }
        if low.hasPrefix("confirm") || low.hasPrefix("yes") { return false }
        let head = String(low.prefix(40))
        return head.contains("reject") && !head.contains("confirm")
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

    /// True only if the evidence quote is genuinely grounded in the transcript.
    /// Grounding requires ONE of: a (near-)verbatim substring; a contiguous
    /// 4-word phrase from the quote appearing verbatim; or a MAJORITY (≥60%) of
    /// the quote's substantive (≥4-char) words present. The old rule — a single
    /// shared ≥4-char word — let a fabricated quote containing "patient" or
    /// "would" pass, which is exactly the over-scoring this guardrail exists to
    /// stop. Empty/none/short-unmatched quotes return false.
    private static func isSupported(_ evidence: String?, by transcript: String) -> Bool {
        guard let evidence, !evidence.isEmpty else { return false }
        let t = normalize(transcript)
        let e = normalize(evidence)
        guard !e.isEmpty else { return false }
        if t.range(of: e) != nil { return true }   // (near-)verbatim

        let evidenceWords = e.split(separator: " ").map(String.init)

        // A contiguous 4-word run of the quote appearing verbatim in the
        // transcript is strong grounding even if the whole quote isn't verbatim.
        if evidenceWords.count >= 4 {
            for start in 0...(evidenceWords.count - 4) {
                let phrase = evidenceWords[start..<start + 4].joined(separator: " ")
                if t.range(of: phrase) != nil { return true }
            }
        }

        // Otherwise require a majority of the substantive words to be present;
        // one shared common word is not evidence a quote is real.
        let transcriptWords = Set(t.split(separator: " ").map(String.init))
        let contentWords = evidenceWords.filter { $0.count >= 4 }
        guard contentWords.count >= 2 else { return false }
        let present = contentWords.filter { transcriptWords.contains($0) }.count
        return Double(present) / Double(contentWords.count) >= 0.6
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
