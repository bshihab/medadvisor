import Foundation

/// The on-device model the app manages (just the LLM now — Apple's speech
/// engine ships with iOS and needs no managed download).
enum ManagedModel: String, CaseIterable, Identifiable {
    case llm
    var id: String { rawValue }

    var title: String {
        switch self {
        case .llm: return "Qwen 2.5-7B"
        }
    }
    var role: String {
        switch self {
        case .llm: return "AI feedback"
        }
    }
    var approxSize: String {
        switch self {
        case .llm: return "~4.3 GB"
        }
    }
    /// The LLM is downloaded up front.
    var downloadsOnFirstUse: Bool { false }
}

/// Tracks install-state and deletion for all three models. Bump `revision` to
/// refresh views after a change.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published private(set) var revision = 0

    /// Bump so views re-check install state (e.g. after a background download).
    func modelChanged() { revision += 1 }

    func isInstalled(_ model: ManagedModel) -> Bool {
        switch model {
        case .llm: return ModelDownloader.shared.isDownloaded
        }
    }

    func delete(_ model: ManagedModel) {
        switch model {
        case .llm: ModelDownloader.shared.delete()   // removes the Background Assets pack
        }
        revision += 1
    }
}
