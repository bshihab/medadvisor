import Foundation
import MLXLLM
import MLXLMCommon

/// Shared on-device LLM. Loads the model once and is reused by both the spike
/// and the consultation analyzer (avoids loading two copies into memory).
/// Mirrors the exact MLX call pattern proven in the M0 spike.
@MainActor
final class LLMEngine {
    static let shared = LLMEngine()
    private init() {}

    /// On-device model. Qwen2.5-1.5B (~870MB) fits the phone's per-app memory
    /// limit (we can't use the increased-memory entitlement) while still
    /// following the per-criterion format well. Final choice pending the M3 eval.
    let modelId = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"

    private var container: ModelContainer?
    var isLoaded: Bool { container != nil }

    func ensureLoaded(progress: @escaping (Double) -> Void = { _ in }) async throws {
        if container != nil { return }
        let config = ModelConfiguration(id: modelId)
        container = try await LLMModelFactory.shared.loadContainer(configuration: config) { p in
            Task { @MainActor in progress(p.fractionCompleted) }
        }
    }

    /// Generate a completion. `onPartial` streams the decoded text so far.
    func generate(prompt: String,
                  maxTokens: Int = 700,
                  temperature: Float = 0.3,
                  onPartial: @escaping (String) -> Void = { _ in }) async throws -> String {
        try await ensureLoaded()
        guard let container else { throw LLMError.notLoaded }
        return try await container.perform { context -> String in
            let input = try await context.processor.prepare(input: UserInput(prompt: prompt))
            let gen = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(temperature: temperature),
                context: context
            ) { tokens in
                if tokens.count % 16 == 0 {
                    let text = Self.clean(context.tokenizer.decode(tokens: tokens))
                    Task { @MainActor in onPartial(text) }
                }
                return tokens.count >= maxTokens ? .stop : .more
            }
            return Self.clean(gen.output)
        }
    }

    /// Strip Gemma chat-template markers that can bleed into generated text,
    /// and cut anything after an end-of-turn marker.
    nonisolated private static func clean(_ s: String) -> String {
        var text = s
        // Strip chat-template markers from any model family (Gemma, Qwen, etc.).
        for marker in ["<end_of_turn>", "<eos>", "<start_of_turn>",
                       "<|im_end|>", "<|im_start|>", "<|endoftext|>"] {
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
