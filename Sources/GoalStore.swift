import Foundation

/// Stores the user's pinned focus phase (one of the 5 phase ids, shared across
/// rubrics). The pinned phase is surfaced at the top of feedback with a marker.
@MainActor
final class GoalStore: ObservableObject {
    static let shared = GoalStore()

    private let key = "pinnedPhaseId"

    @Published var pinnedPhaseId: String? {
        didSet { UserDefaults.standard.set(pinnedPhaseId, forKey: key) }
    }

    init() {
        pinnedPhaseId = UserDefaults.standard.string(forKey: key)
    }

    func toggle(_ id: String) {
        pinnedPhaseId = (pinnedPhaseId == id) ? nil : id
    }

    func isPinned(_ id: String) -> Bool { pinnedPhaseId == id }
}
