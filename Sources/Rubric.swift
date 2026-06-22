import Foundation

/// Swift model of a rubric (subset of rubric.schema.json — Codable ignores keys
/// we don't declare, so `source`, `scoring`, etc. are tolerated and skipped).
struct Rubric: Codable, Equatable {
    let id: String
    let name: String
    let encounterType: String
    let version: String
    let dimensions: [Dimension]?
    let criteria: [Criterion]
}

struct Dimension: Codable, Equatable {
    let id: String
    let label: String
    let description: String?
}

struct Criterion: Codable, Equatable, Identifiable {
    let id: String
    let dimension: String
    let prompt: String
    let responseType: String
    let weight: Double
    let whatGoodLooksLike: String?
    let requiredElements: [String]?
    let exemplarQuotes: [String]?
    let criticalFail: Bool?
}

enum RubricLoader {
    /// Loads a rubric bundled with the app by base filename (no extension).
    static func load(named name: String) -> Rubric? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(Rubric.self, from: data)
    }
}
