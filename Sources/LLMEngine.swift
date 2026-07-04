import Foundation

/// Shared on-device LLM. Runs Qwen2.5-7B-Instruct via llama.cpp (LlamaContext).
/// llama.cpp mmaps the weights, so a 7B Q4 model (~4.3GB) fits under the iOS
/// app-memory limit without the increased-memory entitlement (MLX could not).
/// Qwen chosen over MedGemma 4B after benchmarking (see tools/llm-benchmark).
@MainActor
final class LLMEngine {
    static let shared = LLMEngine()
    private init() {}

    private var llama: LlamaContext?

    var isLoaded: Bool { llama != nil }

    /// Frees the model from memory.
    func unload() { llama = nil }

    /// Ensures the model is downloaded (first run, ~4.3GB) and loaded.
    /// `progress` reports the download fraction (0...1).
    func ensureLoaded(progress: @escaping (Double) -> Void = { _ in }) async throws {
        if llama != nil { return }
        let modelURL = try await ModelDownloader.shared.ensureModel(onProgress: progress)
        llama = try LlamaContext(modelPath: modelURL.path)
    }

    /// Generate a completion. `onPartial` streams the decoded text so far.
    func generate(prompt: String,
                  maxTokens: Int = 512,
                  onPartial: @escaping (String) -> Void = { _ in }) async throws -> String {
        try await ensureLoaded()
        guard let llama else { throw LLMError.notLoaded }

        // Qwen uses the ChatML template — wrong markers = garbage output.
        let formatted = "<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n"

        var output = ""
        for await piece in llama.predict(prompt: formatted, maxTokens: maxTokens) {
            output += piece
            onPartial(Self.clean(output))
        }
        return Self.clean(output)
    }

    /// Generate against a shared cached prefix + short per-call suffix.
    /// The prefix's KV state (e.g. examiner instructions + the transcript) is
    /// computed once and reused across calls with the same prefix — cutting
    /// per-criterion prompt processing to just the question. Identical tokens
    /// to a plain `generate(prompt: prefix + suffix)`, so accuracy is unchanged.
    func generate(sharedPrefix: String, suffix: String,
                  maxTokens: Int = 512,
                  onPartial: @escaping (String) -> Void = { _ in }) async throws -> String {
        try await ensureLoaded()
        guard let llama else { throw LLMError.notLoaded }

        let prefix = "<|im_start|>user\n" + sharedPrefix
        let fullSuffix = suffix + "<|im_end|>\n<|im_start|>assistant\n"

        var output = ""
        for await piece in llama.predict(prefix: prefix, suffix: fullSuffix, maxTokens: maxTokens) {
            output += piece
            onPartial(Self.clean(output))
        }
        return Self.clean(output)
    }

    nonisolated private static func clean(_ s: String) -> String {
        var text = s
        for marker in ["<|im_end|>", "<|endoftext|>", "<|im_start|>"] {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum LLMError: Error, LocalizedError {
        case notLoaded
        var errorDescription: String? { "Model not loaded." }
    }
}
