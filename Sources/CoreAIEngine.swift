import Foundation

// DORMANT BY DESIGN. The Core AI runtime ships as a Swift package
// (apple/coreai-models) that is not part of the iOS SDK, and this target no
// longer links it — so this whole file compiles out. It is kept as a working
// starting point, not dead weight: the spike below established exactly what
// blocks Core AI on this app, and exactly what would have to change first.
#if canImport(CoreAILanguageModels)
import FoundationModels
import CoreAILanguageModels

/// Core AI backend (iOS 27+): an Apple-exported `.aimodel` run through
/// FoundationModels' `LanguageModelSession`, targeting the Neural Engine.
///
/// ## Why this is shelved (measured, July 2026, iPhone 17 / 8 GB / iOS 27.0)
///
/// 1. **It cannot beat the model we already ship.** Apple's iOS export recipes
///    top out at Qwen3-4B — 8B is macOS-only and there is no Qwen2.5-7B iOS
///    recipe at all. Production runs Qwen2.5-7B on llama.cpp, so even a total
///    Core AI success is a step down in quality.
/// 2. **Memory accounting, not the chip, is the wall.** Core AI loads weights
///    as counted app memory; llama.cpp mmaps them (file-backed, evictable —
///    a 4.3 GB GGUF measures a 495 MB peak footprint). iOS 27 also moved
///    Neural Engine memory onto the app's own jetsam ledger. Net effect: the
///    2.4 GB Core AI 4B dies where the 4.3 GB llama model runs fine.
/// 3. **The 4B never loaded, by any route.** Raw `.aimodel` on ANE: jetsam at
///    load. Mac-AOT-compiled `.aimodelc` on ANE: the residual device
///    specialization ground 10–30 min at high heat and was killed by the
///    system every time (5 attempts, no cumulative progress, multi-GB of
///    orphaned cache per try). Forced onto the GPU: palettized weights inflate
///    during pipeline materialization and blow the budget inside a single
///    graph. As a macOS-style dynamic export on the GPU pipelined engine: the
///    engine came up in 180 MB, then died materializing the graph at first
///    prefill.
/// 4. **Prefix caching does not work for this app's shape.** Scoring fans 16
///    criteria off one shared transcript prefix. Upstream hardcodes
///    `Usage.Input.cachedTokenCount` to 0, and — the real problem — every
///    engine full-resets its KV cache when a request diverges from the
///    previous one, which our fan-out does by construction. Measured on the
///    working 0.6B: `cached = 0` on all 16 criteria, versus llama.cpp's
///    18.6 s → 7.3 s drop from a warm prefix.
///
/// What *did* work: **Qwen3-0.6B on the Neural Engine** — ~5 s cached load,
/// ~43 tok/s, a complete 16-criterion analysis. Too small to score on.
///
/// ## Reviving this
///
/// The trigger worth waiting for is Apple shipping **file-backed (mmap'd)
/// weights for iOS exports**, which would remove blocker 2 and probably 3.
/// Watch apple/coreai-models for runtime/Swift-side changes — the mmap work
/// as of 04a3fd6 was host-side export tooling only and does not affect the
/// device. Then:
///
/// - Add the package back (`packages:` + `CoreAILM` product) and raise
///   `deploymentTarget` to 27.0. Note this is the packaging wall behind
///   "one binary, two engines": the package refuses to link below iOS 27, so
///   shipping both engines means isolating this one in a weak-linked
///   framework with its own deployment target.
/// - Export a model on an arm64 Mac and bundle the output **folder** as a
///   folder reference (a group flattens it and the tokenizer lookup breaks):
///
///       uv run coreai.llm.export Qwen/Qwen3-0.6B --platform iOS --output-dir ./my-models/
///
/// - `--max-context-length` must be a rung of the compiled shape ladder
///   (256·2ⁿ). The exporter stamps any value into metadata but only compiles
///   {256,512,1024,2048,4096} × query {8,16,64}; a mismatch fails at load with
///   "failed to find an extend function". 4096 is the practical ceiling, below
///   llama.cpp's n_ctx = 6144.
/// - Qwen3 is a reasoning model: without `/no_think` appended to the user turn
///   it spends the whole token budget inside `<think>` and returns nothing.
///   Gate that on `model.capabilities.contains(.reasoning)` — Qwen2.5 has no
///   thinking mode and would just receive the literal text.
@available(iOS 27.0, *)
@MainActor
final class CoreAIEngine: InferenceEngine {
    let label = "Core AI · Neural Engine"
    let requiresManagedDownload = false   // the model ships in the app bundle

    /// Exported resource folder, bundled with the app. Must match the
    /// `Models/` folder reference in project.yml.
    static let modelFolderName = "qwen3_0_6b_mixed_4bit_8bit_static"

    static var bundleURL: URL? {
        Bundle.main.url(forResource: modelFolderName, withExtension: nil)
    }

    private var model: CoreAILanguageModel?

    var isLoaded: Bool { model != nil }

    func unload() { model = nil }

    func ensureLoaded(progress: @escaping (Double) -> Void) async throws {
        if model != nil { return }
        guard let url = Self.bundleURL else { throw InferenceError.notLoaded }
        // `.eager`, not the default `.lazy`: lazy defers the engine load — and,
        // on a first run, minutes of one-time device specialization — into the
        // first generation, where it looks like a hang and is charged to the
        // wrong pipeline stage.
        model = try await CoreAILanguageModel(resourcesAt: url, mode: .eager)
    }

    func generate(prompt: String,
                  maxTokens: Int,
                  onPartial: @escaping (String) -> Void) async throws -> String {
        try await ensureLoaded(progress: { _ in })
        guard let model else { throw InferenceError.notLoaded }
        return try await respond(session: LanguageModelSession(model: model),
                                 to: prompt, maxTokens: maxTokens, onPartial: onPartial)
    }

    /// A fresh session per criterion keeps the 16 criteria independent; the
    /// shared prefix becomes the session's instructions. See finding 4 above
    /// for why the framework does not actually reuse that prefix.
    func generate(sharedPrefix: String,
                  suffix: String,
                  maxTokens: Int,
                  onPartial: @escaping (String) -> Void) async throws -> String {
        try await ensureLoaded(progress: { _ in })
        guard let model else { throw InferenceError.notLoaded }
        return try await respond(session: LanguageModelSession(model: model,
                                                               instructions: sharedPrefix),
                                 to: suffix, maxTokens: maxTokens, onPartial: onPartial)
    }

    private func respond(session: LanguageModelSession,
                         to prompt: String,
                         maxTokens: Int,
                         onPartial: @escaping (String) -> Void) async throws -> String {
        // Reasoning models burn the whole token budget inside <think> unless
        // told not to; non-reasoning models would just see the literal switch.
        let promptText = (model?.capabilities.contains(.reasoning) ?? false)
            ? prompt + "\n/no_think" : prompt
        let t0 = Date()
        let response = try await session.respond(
            to: promptText, options: GenerationOptions(maximumResponseTokens: maxTokens))
        onPartial(response.content)

        let usage = response.usage
        BenchmarkRecorder.shared.recordGeneration(
            phase: BenchmarkRecorder.shared.currentPhase,
            tokens: usage.output.totalTokenCount,
            seconds: Date().timeIntervalSince(t0),
            cachedInputTokens: usage.input.cachedTokenCount)
        return response.content
    }
}

#endif
