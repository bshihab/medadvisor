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

    /// Small model to prove the pipeline; swap to Gemma 3n / larger quant later.
    let modelId = "mlx-community/gemma-2-2b-it-4bit"

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
                    let text = context.tokenizer.decode(tokens: tokens)
                    Task { @MainActor in onPartial(text) }
                }
                return tokens.count >= maxTokens ? .stop : .more
            }
            return gen.output
        }
    }

    enum LLMError: Error, LocalizedError {
        case notLoaded
        var errorDescription: String? { "Model not loaded." }
    }
}
