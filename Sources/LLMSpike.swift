import Foundation
import MLXLLM
import MLXLMCommon

/// M0 spike: prove a quantized LLM loads and generates ON-DEVICE.
///
/// NOTE ON THE MLX API: mlx-swift-examples changes its API between versions.
/// This is written against a recent `main`; if it doesn't compile, paste the
/// Xcode errors and we'll adjust the call sites — the shape (load container →
/// prepare input → generate with a token callback) is stable, the exact names move.
@MainActor
final class LLMSpike: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading(String)
        case ready
        case generating
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var output: String = ""

    /// Small model to prove the pipeline cheaply. Swap to a Gemma 3n / larger
    /// quant once this runs. First load DOWNLOADS the weights (needs network once);
    /// afterwards it runs fully offline from the on-device cache.
    private let modelId = "mlx-community/gemma-2-2b-it-4bit"
    private var container: ModelContainer?

    func loadIfNeeded() async {
        guard container == nil else { return }
        phase = .loading("Loading model…")
        do {
            let config = ModelConfiguration(id: modelId)
            container = try await LLMModelFactory.shared.loadContainer(configuration: config) { progress in
                Task { @MainActor in
                    self.phase = .loading("Loading… \(Int(progress.fractionCompleted * 100))%")
                }
            }
            phase = .ready
        } catch {
            phase = .error("Load failed: \(error.localizedDescription)")
        }
    }

    func generate(prompt: String) async {
        await loadIfNeeded()
        guard let container else { return }
        phase = .generating
        output = ""
        do {
            let result = try await container.perform { context -> String in
                let input = try await context.processor.prepare(input: UserInput(prompt: prompt))
                let gen = try MLXLMCommon.generate(
                    input: input,
                    parameters: GenerateParameters(temperature: 0.6),
                    context: context
                ) { tokens in
                    if tokens.count % 8 == 0 {
                        let text = context.tokenizer.decode(tokens: tokens)
                        Task { @MainActor in self.output = text }
                    }
                    return tokens.count >= 400 ? .stop : .more
                }
                return gen.output
            }
            output = result
            phase = .ready
        } catch {
            phase = .error("Generation failed: \(error.localizedDescription)")
        }
    }
}
