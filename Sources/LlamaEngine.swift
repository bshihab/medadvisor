import Foundation

/// llama.cpp backend: Qwen2.5-7B-Instruct Q4_K_M (GGUF), every layer offloaded
/// to the GPU via Metal. Runs on iOS 26+, and before Core AI it was the only
/// path that could run a 7B on a phone at all.
///
/// llama.cpp mmaps the weights, so the ~4.3GB model doesn't count against the
/// iOS app-memory limit (MLX could not do this without the increased-memory
/// entitlement). Qwen chosen over MedGemma 4B after benchmarking — see
/// tools/llm-benchmark.
///
/// Everything Qwen-specific lives here: the ChatML template and the marker
/// cleanup. A Core AI backend would express the same contract completely
/// differently, which is the point of the protocol.
@MainActor
final class LlamaEngine: InferenceEngine {
    let label = "llama.cpp · GPU (Metal)"

    private var llama: LlamaContext?

    var isLoaded: Bool { llama != nil }

    func unload() { llama = nil }

    func ensureLoaded(progress: @escaping (Double) -> Void) async throws {
        if llama != nil { return }
        let modelURL = try await ModelDownloader.shared.ensureModel(onProgress: progress)
        llama = try LlamaContext(modelPath: modelURL.path)
    }

    func generate(prompt: String,
                  maxTokens: Int,
                  onPartial: @escaping (String) -> Void) async throws -> String {
        try await ensureLoaded(progress: { _ in })
        guard let llama else { throw InferenceError.notLoaded }

        // Qwen uses the ChatML template — wrong markers = garbage output.
        let formatted = "<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n"

        var output = ""
        var tokens = 0
        let t0 = Date()
        for await piece in llama.predict(prompt: formatted, maxTokens: maxTokens) {
            tokens += 1
            output += piece
            onPartial(Self.clean(output))
        }
        BenchmarkRecorder.shared.recordGeneration(
            phase: BenchmarkRecorder.shared.currentPhase,
            tokens: tokens, seconds: Date().timeIntervalSince(t0))
        return Self.clean(output)
    }

    /// The prefix's KV state is computed once and reused across calls sharing it,
    /// cutting per-criterion prompt processing to just the question. Identical
    /// tokens to `generate(prompt: sharedPrefix + suffix)`, so accuracy is
    /// unchanged — only the cost differs.
    func generate(sharedPrefix: String,
                  suffix: String,
                  maxTokens: Int,
                  onPartial: @escaping (String) -> Void) async throws -> String {
        try await ensureLoaded(progress: { _ in })
        guard let llama else { throw InferenceError.notLoaded }

        let prefix = "<|im_start|>user\n" + sharedPrefix
        let fullSuffix = suffix + "<|im_end|>\n<|im_start|>assistant\n"

        var output = ""
        var tokens = 0
        let t0 = Date()
        for await piece in llama.predict(prefix: prefix, suffix: fullSuffix, maxTokens: maxTokens) {
            tokens += 1
            output += piece
            onPartial(Self.clean(output))
        }
        BenchmarkRecorder.shared.recordGeneration(
            phase: BenchmarkRecorder.shared.currentPhase,
            tokens: tokens, seconds: Date().timeIntervalSince(t0))
        return Self.clean(output)
    }

    /// Strip the ChatML markers Qwen emits around and after its answer.
    nonisolated private static func clean(_ s: String) -> String {
        var text = s
        for marker in ["<|im_end|>", "<|endoftext|>", "<|im_start|>"] {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
