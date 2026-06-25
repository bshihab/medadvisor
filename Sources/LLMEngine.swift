import Foundation

/// Shared on-device LLM. Runs MedGemma 4B via llama.cpp (LlamaContext).
/// llama.cpp mmaps the weights, so a 4B model fits under the iOS app-memory
/// limit without the increased-memory entitlement (MLX could not).
@MainActor
final class LLMEngine {
    static let shared = LLMEngine()
    private init() {}

    private var llama: LlamaContext?

    var isLoaded: Bool { llama != nil }

    /// Frees the model from memory.
    func unload() { llama = nil }

    /// Ensures the model is downloaded (first run, ~2.5GB) and loaded.
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

        // MedGemma is Gemma-based — wrap the prompt in Gemma's chat template.
        let formatted = "<start_of_turn>user\n\(prompt)<end_of_turn>\n<start_of_turn>model\n"

        var output = ""
        for await piece in llama.predict(prompt: formatted, maxTokens: maxTokens) {
            output += piece
            onPartial(Self.clean(output))
        }
        return Self.clean(output)
    }

    nonisolated private static func clean(_ s: String) -> String {
        var text = s
        for marker in ["<end_of_turn>", "<eos>", "<start_of_turn>"] {
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
