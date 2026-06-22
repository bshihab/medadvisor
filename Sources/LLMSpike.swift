import Foundation

/// M0 spike VM — now delegates to the shared `LLMEngine`.
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

    func generate(prompt: String) async {
        phase = .loading("Loading model…")
        do {
            try await LLMEngine.shared.ensureLoaded { fraction in
                self.phase = .loading("Loading… \(Int(fraction * 100))%")
            }
            phase = .generating
            output = ""
            let result = try await LLMEngine.shared.generate(prompt: prompt, maxTokens: 400) { partial in
                self.output = partial
            }
            output = result
            phase = .ready
        } catch {
            phase = .error("Failed: \(error.localizedDescription)")
        }
    }
}
