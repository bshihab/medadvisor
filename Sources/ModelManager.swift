import Foundation

/// Directories we own for the on-device speech models, so we can reliably check
/// whether they're installed and delete them. (The LLM is managed separately by
/// ModelDownloader, which owns its .gguf file.)
enum ModelPaths {
    static var base: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var whisperBase: URL { base.appendingPathComponent("whisper", isDirectory: true) }
    static var parakeetBase: URL { base.appendingPathComponent("parakeet", isDirectory: true) }
}

/// The three on-device models the app manages.
enum ManagedModel: String, CaseIterable, Identifiable {
    case llm, whisper, parakeet
    var id: String { rawValue }

    var title: String {
        switch self {
        case .llm:      return "MedGemma 4B"
        case .whisper:  return "Whisper (small.en)"
        case .parakeet: return "Parakeet"
        }
    }
    var role: String {
        switch self {
        case .llm:      return "AI feedback"
        case .whisper:  return "Speech-to-text"
        case .parakeet: return "Speech-to-text"
        }
    }
    var approxSize: String {
        switch self {
        case .llm:      return "~2.5 GB"
        case .whisper:  return "~480 MB"
        case .parakeet: return "~600 MB"
        }
    }
    /// The LLM is downloaded up front; the speech models download automatically
    /// the first time they're used.
    var downloadsOnFirstUse: Bool { self != .llm }
}

/// Tracks install-state and deletion for all three models. Bump `revision` to
/// refresh views after a change.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published private(set) var revision = 0

    func isInstalled(_ model: ManagedModel) -> Bool {
        switch model {
        case .llm:      return ModelDownloader.shared.isDownloaded
        case .whisper:  return Self.directoryHasContents(ModelPaths.whisperBase)
        case .parakeet: return Self.directoryHasContents(ModelPaths.parakeetBase)
        }
    }

    func delete(_ model: ManagedModel) {
        switch model {
        case .llm:      try? FileManager.default.removeItem(at: ModelDownloader.shared.localURL)
        case .whisper:  try? FileManager.default.removeItem(at: ModelPaths.whisperBase)
        case .parakeet: try? FileManager.default.removeItem(at: ModelPaths.parakeetBase)
        }
        revision += 1
    }

    /// True if the model directory exists and contains at least one file.
    private static func directoryHasContents(_ url: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil) else { return false }
        return !items.isEmpty
    }
}
