import Foundation

/// The clinical setting chosen at the start of a session. Drives which rubric loads.
enum AppLocation: String, CaseIterable, Identifiable {
    case outpatientClinic = "Outpatient Clinic"
    case inpatient = "Inpatient"
    case emergencyDepartment = "Emergency Dept"
    case operatingRoom = "Operating Room"

    var id: String { rawValue }

    /// Bundled rubric filename (without .json). Per the director, the Emergency
    /// Department and perioperative/OR encounters use the Inpatient framework.
    var rubricFile: String {
        switch self {
        case .outpatientClinic:    return "outpatient-clinic"
        case .inpatient,
             .emergencyDepartment,
             .operatingRoom:       return "inpatient"
        }
    }

    /// Short description shown on the location-selection card.
    var blurb: String {
        switch self {
        case .outpatientClinic:    return "A scheduled clinic visit — history taking and explaining a plan."
        case .inpatient:           return "Bedside rounds on the ward or ICU — talking with the patient and family."
        case .emergencyDepartment: return "A fast, high-acuity emergency encounter (inpatient framework)."
        case .operatingRoom:       return "Peri-operative patient communication (inpatient framework)."
        }
    }
}

/// Swift model of a rubric (subset of rubric.schema.json — Codable ignores keys
/// we don't declare, so `scoring`, `requiredElements`, etc. are tolerated).
struct Rubric: Codable, Equatable {
    let id: String
    let name: String
    let location: String?
    let encounterType: String?
    let version: String
    let dimensions: [Dimension]
    let criteria: [Criterion]
}

struct Dimension: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let description: String?
    let coaching: PhaseCoaching?
}

/// Goal-setting content for one phase.
struct PhaseCoaching: Codable, Equatable {
    let whyItMatters: String?
    let examplePhrases: [String]?
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
    static func load(named name: String) -> Rubric? {
        // Cloud-refreshed copy first (director's latest edits), bundle as the
        // always-works fallback.
        if let cloud = RubricSync.cached(named: name) { return cloud }
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(Rubric.self, from: data)
    }

    static func load(for location: AppLocation) -> Rubric? {
        load(named: location.rubricFile)
    }
}
