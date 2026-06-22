import Foundation

/// The clinical setting chosen at the start of a session. Drives which rubric loads.
enum AppLocation: String, CaseIterable, Identifiable {
    case outpatientClinic = "Outpatient Clinic"
    case inpatient = "Inpatient"
    case emergencyDepartment = "Emergency Dept"
    case operatingRoom = "Operating Room"

    var id: String { rawValue }

    /// Bundled rubric filename (without .json).
    var rubricFile: String {
        switch self {
        case .outpatientClinic:    return "outpatient-clinic"
        case .inpatient:           return "inpatient"
        case .emergencyDepartment: return "emergency-department.draft"
        case .operatingRoom:       return "operating-room.draft"
        }
    }

    /// True for locations the director hasn't supplied material for yet.
    var isDraft: Bool {
        self == .emergencyDepartment || self == .operatingRoom
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
