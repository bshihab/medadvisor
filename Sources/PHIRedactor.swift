import Foundation
import NaturalLanguage

/// M2 redaction (M4 will harden + measure this). Removes PHI from a transcript
/// BEFORE it reaches the LLM: structured identifiers via regex, names/places/orgs
/// via on-device NER. Everything runs locally.
enum PHIRedactor {
    static func redact(_ text: String) -> String {
        var result = text

        // 1) Structured identifiers (order matters: most specific first).
        let patterns: [(pattern: String, replacement: String)] = [
            ("\\b\\d{3}-\\d{2}-\\d{4}\\b", "[SSN]"),
            ("\\b\\d{1,2}[/.-]\\d{1,2}[/.-]\\d{2,4}\\b", "[DATE]"),
            ("\\b(?:\\+?\\d{1,2}[ .-]?)?\\(?\\d{3}\\)?[ .-]?\\d{3}[ .-]?\\d{4}\\b", "[PHONE]"),
            ("\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b", "[EMAIL]"),
            ("\\b[A-Z]{2,4}\\d{4,}\\b", "[ID]"), // MRN-like
            ("\\b\\d+\\s+[A-Z][a-zA-Z]+\\s+(?:Street|St|Avenue|Ave|Road|Rd|Lane|Ln|Drive|Dr|Boulevard|Blvd)\\b", "[ADDRESS]")
        ]
        for (pattern, replacement) in patterns {
            result = result.replacingOccurrences(
                of: pattern, with: replacement, options: .regularExpression
            )
        }

        // 2) Named entities (on-device).
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = result
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

        var replacements: [(range: Range<String.Index>, token: String)] = []
        tagger.enumerateTags(in: result.startIndex..<result.endIndex,
                             unit: .word, scheme: .nameType, options: options) { tag, range in
            switch tag {
            case .personalName:     replacements.append((range, "[NAME]"))
            case .placeName:        replacements.append((range, "[PLACE]"))
            case .organizationName: replacements.append((range, "[ORG]"))
            default: break
            }
            return true
        }
        // Apply in reverse so earlier ranges stay valid.
        for (range, token) in replacements.reversed() {
            result.replaceSubrange(range, with: token)
        }

        return result
    }
}
