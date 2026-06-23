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

    /// Short description shown on the location-selection card.
    var blurb: String {
        switch self {
        case .outpatientClinic:    return "A scheduled clinic visit — history taking and explaining a plan."
        case .inpatient:           return "Bedside rounds on the ward or ICU — talking with the patient and family."
        case .emergencyDepartment: return "A fast, high-acuity emergency encounter."
        case .operatingRoom:       return "Peri-operative and pre-op patient communication."
        }
    }

    /// True for locations with no source material distilled into the rubric yet.
    var isDraft: Bool {
        self == .emergencyDepartment || self == .operatingRoom
    }

    /// Note shown for draft locations.
    var draftNote: String { "No reference info yet — generalized draft" }
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
