import Foundation
import UIKit

/// The app's single entry point to on-device inference.
///
/// A thin facade over whichever `InferenceEngine` backend is active, so callers
/// (EncounterProcessor, InsightsView) never care which engine is running — and
/// so the default arguments a protocol can't declare live in exactly one place.
///
/// Backend selection happens in `init`. Today it's always llama.cpp on the GPU;
/// when the Core AI path lands it becomes a one-line availability check and
/// nothing else in the app changes.
@MainActor
final class LLMEngine {
    static let shared = LLMEngine()

    private let engine: InferenceEngine

    /// Reentrancy guard for memory-warning unloads: >0 means a generation is in
    /// flight, so the model must NOT be freed (that would abort scoring).
    private var inUseCount = 0

    /// Dev override for which backend runs. The whole point of the spike: it lets
    /// ONE phone measure llama.cpp/GPU against Core AI/Neural Engine with the
    /// hardware, OS, and script held constant, so the engine is the only variable.
    enum EnginePreference: String, CaseIterable, Identifiable {
        case auto, llama, coreAI
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto:   return "Automatic"
            case .llama:  return "llama.cpp (GPU)"
            case .coreAI: return "Core AI (Neural Engine)"
            }
        }
    }

    static let preferenceKey = "enginePreference"

    /// Read once — the engine is chosen at construction, so changing the
    /// preference needs an app relaunch to take effect.
    private init() {
        let pref = EnginePreference(
            rawValue: UserDefaults.standard.string(forKey: Self.preferenceKey) ?? "") ?? .auto

        // Core AI only exists once the SPM package is linked (it is NOT in the
        // SDK), and only on iOS 27+. Everything else falls back to llama.cpp —
        // which on main is the only path, keeping the director's build untouched.
        #if canImport(CoreAILanguageModels)
        if pref != .llama, #available(iOS 27.0, *) {
            engine = CoreAIEngine()
            registerMemoryWarningObserver()
            return
        }
        #endif
        engine = LlamaEngine()
        registerMemoryWarningObserver()
    }

    /// Under memory pressure, free the resident model when idle so the app is a
    /// smaller jetsam target in the background (the resident-model optimization
    /// otherwise makes it the first thing iOS kills). Weights are mmap'd; this
    /// reclaims the KV cache + context. Never fires mid-generation (inUseCount).
    private func registerMemoryWarningObserver() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.inUseCount == 0 else { return }
                self.unload()
            }
        }
    }

    /// Label of the active backend — stamped onto benchmark runs so a result
    /// JSON always says which engine produced it.
    var label: String { engine.label }

    /// Whether the active backend needs the ModelDownloader-managed GGUF.
    /// Core AI's model ships in the bundle, so the pipeline must not gate
    /// analysis on a download that engine never reads.
    var requiresManagedDownload: Bool { engine.requiresManagedDownload }

    var isLoaded: Bool { engine.isLoaded }

    func unload() { engine.unload() }

    /// Ensures the model is downloaded (first run, ~4.3GB) and loaded.
    /// `progress` reports the download fraction (0...1).
    func ensureLoaded(progress: @escaping (Double) -> Void = { _ in }) async throws {
        try await engine.ensureLoaded(progress: progress)
    }

    /// Generate a completion. `onPartial` streams the decoded text so far.
    func generate(prompt: String,
                  maxTokens: Int = 512,
                  onPartial: @escaping (String) -> Void = { _ in }) async throws -> String {
        inUseCount += 1
        defer { inUseCount -= 1 }
        return try await engine.generate(prompt: prompt, maxTokens: maxTokens, onPartial: onPartial)
    }

    /// Generate against a shared cached prefix + short per-call suffix — see
    /// `InferenceEngine` for why this matters to the 16-criterion loop.
    func generate(sharedPrefix: String, suffix: String,
                  maxTokens: Int = 512,
                  onPartial: @escaping (String) -> Void = { _ in }) async throws -> String {
        inUseCount += 1
        defer { inUseCount -= 1 }
        return try await engine.generate(sharedPrefix: sharedPrefix, suffix: suffix,
                                        maxTokens: maxTokens, onPartial: onPartial)
    }
}
