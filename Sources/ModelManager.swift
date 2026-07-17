import Foundation

/// The on-device models the app manages. The LLM (GGUF) is downloaded from R2
/// via ModelDownloader; Apple's speech engine ships with iOS and needs nothing.
/// On the Core AI spike branch, the exported Qwen3-4B rides inside the app
/// bundle, so it shows here as installed-but-not-downloadable.
enum ManagedModel: String, CaseIterable, Identifiable {
    case llm
    #if canImport(CoreAILanguageModels)
    case coreAI
    #endif
    var id: String { rawValue }

    var title: String {
        switch self {
        case .llm: return "Qwen 2.5-7B"
        #if canImport(CoreAILanguageModels)
        case .coreAI: return "Qwen 3-4B (Core AI)"
        #endif
        }
    }
    var role: String {
        switch self {
        case .llm: return "AI feedback · GPU"
        #if canImport(CoreAILanguageModels)
        case .coreAI: return "AI feedback · Neural Engine"
        #endif
        }
    }
    var approxSize: String {
        switch self {
        case .llm: return "~4.3 GB"
        #if canImport(CoreAILanguageModels)
        case .coreAI: return "~2.4 GB"
        #endif
        }
    }
    /// The GGUF is fetched by ModelDownloader and can be removed; the Core AI
    /// model is part of the app bundle — nothing to download, nothing to delete.
    var deletable: Bool {
        switch self {
        case .llm: return true
        #if canImport(CoreAILanguageModels)
        case .coreAI: return false
        #endif
        }
    }
    /// The LLM is downloaded up front.
    var downloadsOnFirstUse: Bool { false }
}

/// Tracks install-state and deletion for the managed models. Bump `revision` to
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
        #if canImport(CoreAILanguageModels)
        // Folder name must match CoreAIEngine.modelFolderName (the export's
        // output directory, added to the target as a folder reference).
        case .coreAI:
            return Bundle.main.url(forResource: "qwen3_4b_mixed_4bit_8bit_static",
                                   withExtension: nil) != nil
        #endif
        }
    }

    func delete(_ model: ManagedModel) {
        switch model {
        case .llm: ModelDownloader.shared.delete()   // removes the Background Assets pack
        #if canImport(CoreAILanguageModels)
        case .coreAI: break   // bundled — not deletable
        #endif
        }
        revision += 1
    }
}
