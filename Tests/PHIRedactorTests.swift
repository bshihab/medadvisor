import XCTest
@testable import MedAdvisor

/// The redactor is a privacy control — regressions here leak PHI into shared /
/// backed-up quotes. These cover the deterministic regex identifiers (NLTagger
/// name/place/org tagging is model-driven and left to on-device QA).
final class PHIRedactorTests: XCTestCase {
    func testRedactsStructuredIdentifiers() {
        let out = PHIRedactor.redact(
            "Call 555-123-4567, SSN 123-45-6789, record 4482913, zip 90210-1234")
        XCTAssertTrue(out.contains("[PHONE]"))
        XCTAssertTrue(out.contains("[SSN]"))
        XCTAssertTrue(out.contains("[ID]"))
        XCTAssertTrue(out.contains("[ZIP]"))
        XCTAssertFalse(out.contains("4482913"))
        XCTAssertFalse(out.contains("123-45-6789"))
    }

    func testPreservesOrdinaryClinicalNumbers() {
        // Under the 7-digit threshold: these are clinical values, not identifiers.
        let out = PHIRedactor.redact("BP was 120 over 80, platelets 150000, gave 5000 units")
        XCTAssertTrue(out.contains("120"))
        XCTAssertTrue(out.contains("150000"))
        XCTAssertTrue(out.contains("5000"))
    }

    func testRedactsEmailAddressAndAdvancedAge() {
        let out = PHIRedactor.redact("email a@b.com, lives at 42 Oak Street, a 92-year-old patient")
        XCTAssertTrue(out.contains("[EMAIL]"))
        XCTAssertTrue(out.contains("[ADDRESS]"))
        XCTAssertTrue(out.contains("[AGE]"))
    }

    func testRedactsPOBox() {
        XCTAssertTrue(PHIRedactor.redact("send to P.O. Box 217").contains("[ADDRESS]"))
    }
}
