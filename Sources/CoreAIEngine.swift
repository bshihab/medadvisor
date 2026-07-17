import Foundation

// The Core AI runtime ships as a Swift package (apple/coreai-models), not in the
// SDK — so this whole file compiles out until that dependency is added. Keeps the
// branch buildable while the model export is still being figured out.
#if canImport(CoreAILanguageModels)
import FoundationModels
import CoreAILanguageModels

/// Core AI backend (iOS 27+): an Apple-optimized Qwen3 exported to `.aimodel`,
/// run through FoundationModels' `LanguageModelSession`.
///
/// The point of this engine is to answer three questions with numbers:
///   1. Does a big model actually execute on the Neural Engine, or fall back to
///      the GPU? (`ComputeUnitKind.availableKinds` + specialization options)
///   2. Does throughput hold under sustained load, where llama.cpp on the GPU
///      degraded 31% / +53% wall-clock across three back-to-back sessions?
///   3. Does scoring quality survive the model change?
///
/// NOTE ON THE MODEL: Apple's iOS support table caps Qwen3 at **4B** — Qwen3-8B
/// is macOS-only, and the qwen2 recipe only covers Qwen2.5-1.5B. So there is no
/// Core AI equivalent of our Qwen2.5-7B on iPhone. This engine is therefore a
/// *newer, smaller* model on a *better chip* — not a like-for-like swap — which
/// is exactly why the rubric has to be re-validated before this could ship.
@available(iOS 27.0, *)
@MainActor
final class CoreAIEngine: InferenceEngine {
    let label = "Core AI · Qwen3-4B"

    private var model: CoreAILanguageModel?

    var isLoaded: Bool { model != nil }

    func unload() { model = nil }

    /// Name of the exported resource folder (as emitted by the export recipe).
    private static let modelFolderName = "qwen3_4b_mixed_4bit_8bit_static"

    /// The exported model's resource folder, bundled with the app.
    ///
    /// Produced by (on an arm64 Mac — Apple ships the wheels for Apple silicon
    /// only; an Intel-emulated Python can't install coreai-core):
    ///
    ///     uv run coreai.llm.export Qwen/Qwen3-4B --platform iOS \
    ///         --max-context-length 6144 --output-dir ./my-models/
    ///
    /// 6144 matches LlamaContext's n_ctx — a ~15 min consultation is ~3-3.5k
    /// tokens of transcript and the whole transcript sits in context for every
    /// criterion. The export defaults to 4096, which would both cap consultation
    /// length AND make any llama.cpp comparison apples-to-oranges.
    ///
    /// The export emits a FOLDER, not a file — model + tokenizer together:
    ///
    ///     qwen3_4b_mixed_4bit_8bit_static/       <- resourcesAt: wants THIS
    ///       ├── metadata.json
    ///       ├── qwen3_4b_mixed_4bit_8bit_static.aimodel/   (main.mlirb, main.hash)
    ///       └── tokenizer/                                 (tokenizer.json, chat_template.jinja, …)
    ///
    /// It must be added to the target as a **folder reference** (blue folder in
    /// Xcode), not a group — a group flattens the subfolders and the tokenizer
    /// lookup breaks.
    ///
    /// 2.4GB bundled is fine for this spike, but not shippable: production would
    /// fetch it the way ModelDownloader already fetches the GGUF.
    private static var resourcesURL: URL? {
        Bundle.main.url(forResource: modelFolderName, withExtension: nil)
    }

    func ensureLoaded(progress: @escaping (Double) -> Void) async throws {
        if model != nil { return }
        guard let url = Self.resourcesURL else { throw InferenceError.notLoaded }
        // `.eager`, NOT the default `.lazy`: lazy defers the engine load (and,
        // on the first-ever run, minutes of one-time device specialization) to
        // the FIRST generation — which made speaker attribution look hung and
        // would mis-charge the load to attribution in the benchmark. Eager pays
        // it here, inside the stage EncounterProcessor already times as
        // preparingModel / modelLoadSeconds. Compare against llama.cpp's 14.0s.
        //
        // `.fixedSize`, NOT `.auto`: auto starts the KV cache at 256 tokens and
        // grows it as the 3k-token transcript streams in — repeated mid-run
        // reallocations (the memory spikes on the HUD). Fixed pre-allocates the
        // full 6144 up front, which is exactly what LlamaContext does with
        // n_ctx=6144 at init, so the two engines behave symmetrically.
        model = try await CoreAILanguageModel(
            resourcesAt: url,
            mode: .eager,
            kvCacheStrategy: .fixedSize)
    }

    func generate(prompt: String,
                  maxTokens: Int,
                  onPartial: @escaping (String) -> Void) async throws -> String {
        try await ensureLoaded(progress: { _ in })
        guard let model else { throw InferenceError.notLoaded }
        let session = LanguageModelSession(model: model)
        return try await respond(session: session, to: prompt,
                                 maxTokens: maxTokens, onPartial: onPartial)
    }

    /// The whole reason this migration is viable.
    ///
    /// The shared prefix (examiner instructions + transcript) becomes the
    /// session's `instructions`. A *fresh session per criterion* keeps the 16
    /// criteria independent — one long-lived session would let criterion 1's
    /// answer pollute criterion 2's context and grow the prompt every call.
    ///
    /// Reuse comes from underneath: identical model + identical instructions ⇒
    /// identical `executorConfiguration` (which is `Hashable`) ⇒ the framework
    /// resolves to the SAME cached `LanguageModelExecutor`, which diffs
    /// transcripts and preserves the KV cache for the unchanged prefix instead
    /// of re-prefilling the transcript 16 times.
    ///
    /// That is the claim to verify, not assume — `usage.input.cachedTokenCount`
    /// below is the proof. If it stays ~0 across criteria, the prefix is being
    /// reprocessed every call and this design is wrong.
    func generate(sharedPrefix: String,
                  suffix: String,
                  maxTokens: Int,
                  onPartial: @escaping (String) -> Void) async throws -> String {
        try await ensureLoaded(progress: { _ in })
        guard let model else { throw InferenceError.notLoaded }
        let session = LanguageModelSession(model: model, instructions: sharedPrefix)
        return try await respond(session: session, to: suffix,
                                 maxTokens: maxTokens, onPartial: onPartial)
    }

    private func respond(session: LanguageModelSession,
                         to prompt: String,
                         maxTokens: Int,
                         onPartial: @escaping (String) -> Void) async throws -> String {
        let options = GenerationOptions(maximumResponseTokens: maxTokens)
        let t0 = Date()
        let response = try await session.respond(to: prompt, options: options)
        let text = response.content
        onPartial(text)

        // Exact token counts, straight from the framework — better than
        // llama.cpp's piece-counting, and directly comparable.
        let usage = response.usage
        BenchmarkRecorder.shared.recordGeneration(
            phase: BenchmarkRecorder.shared.currentPhase,
            tokens: usage.output.totalTokenCount,
            seconds: Date().timeIntervalSince(t0),
            cachedInputTokens: usage.input.cachedTokenCount)

        print("[CoreAI] in=\(usage.input.totalTokenCount) cached=\(usage.input.cachedTokenCount) out=\(usage.output.totalTokenCount)")
        return text
    }
}

#endif
