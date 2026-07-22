import XCTest
@testable import MedAdvisor

/// The parser turns raw LLM text into scores, including the anti-over-scoring
/// evidence guardrail. Regressions here mis-score every trainee, so these lock
/// in the load-bearing behaviors.
final class FeedbackParserTests: XCTestCase {
    func testDoneWithGroundedQuoteScoresMet() {
        let transcript = "Hello, I'm Doctor Smith, one of the team looking after you today."
        let raw = """
        RESULT: done
        EVIDENCE: I'm Doctor Smith, one of the team looking after you today
        TIP: none
        """
        let r = FeedbackParser.parseCriterion(raw: raw, criterionId: "intro", transcript: transcript)
        XCTAssertEqual(r.status, .met)
        XCTAssertNotNil(r.evidence)
    }

    func testMissedVerdictScoresMissed() {
        let r = FeedbackParser.parseCriterion(
            raw: "RESULT: missed\nEVIDENCE: none\nTIP: introduce yourself",
            criterionId: "intro", transcript: "some unrelated transcript text here")
        XCTAssertEqual(r.status, .missed)
    }

    func testHallucinatedQuoteIsForcedToMissed() {
        // "done", but the quote appears nowhere in the transcript -> the grounding
        // guardrail must downgrade it to missed (the over-scoring we guard against).
        let r = FeedbackParser.parseCriterion(
            raw: "RESULT: done\nEVIDENCE: I completely understand your worries about the surgery\nTIP: none",
            criterionId: "empathy",
            transcript: "The weather is fine and the parking was easy today.")
        XCTAssertEqual(r.status, .missed)
    }

    func testNotApplicableHonoredOnlyWhenAllowed() {
        let na = FeedbackParser.parseCriterion(
            raw: "RESULT: n/a\nEVIDENCE: none\nTIP: none",
            criterionId: "exam", transcript: "text", allowsNA: true)
        XCTAssertEqual(na.status, .notApplicable)

        let notAllowed = FeedbackParser.parseCriterion(
            raw: "RESULT: n/a\nEVIDENCE: none\nTIP: none",
            criterionId: "exam", transcript: "text", allowsNA: false)
        XCTAssertEqual(notAllowed.status, .missed)
    }
}
