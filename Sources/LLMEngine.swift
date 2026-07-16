import Foundation

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

    private init() {
        // Backend selection. iOS 26 can only run a 7B via llama.cpp on the GPU;
        // iOS 27's Core AI targets the Neural Engine instead. When CoreAIEngine
        // exists this becomes:
        //
        //     if #available(iOS 27, *) { engine = CoreAIEngine(); return }
        //
        // Same binary either way — the deployment target stays iOS 26, so the
        // director's phone keeps the GPU path untouched and nobody is stranded.
        engine = LlamaEngine()
    }

    /// Label of the active backend — stamped onto benchmark runs so a result
    /// JSON always says which engine produced it.
    var label: String { engine.label }

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
        try await engine.generate(prompt: prompt, maxTokens: maxTokens, onPartial: onPartial)
    }

    /// Generate against a shared cached prefix + short per-call suffix — see
    /// `InferenceEngine` for why this matters to the 16-criterion loop.
    func generate(sharedPrefix: String, suffix: String,
                  maxTokens: Int = 512,
                  onPartial: @escaping (String) -> Void = { _ in }) async throws -> String {
        try await engine.generate(sharedPrefix: sharedPrefix, suffix: suffix,
                                  maxTokens: maxTokens, onPartial: onPartial)
    }
}
