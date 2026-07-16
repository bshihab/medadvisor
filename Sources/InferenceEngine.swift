import Foundation

/// One on-device inference backend.
///
/// Today there's exactly one conformer — `LlamaEngine` (llama.cpp, every layer
/// on the GPU via Metal), which was the only way to run a 7B on iOS 26. iOS 27's
/// Core AI targets the Neural Engine instead and slots in beside it as a second
/// conformer, so the app can pick a path at runtime while iOS 26 users keep the
/// GPU one. Same binary, no fork.
///
/// Callers never touch this directly — they go through `LLMEngine.shared`, which
/// owns the selected backend and supplies the default arguments a protocol
/// can't declare.
@MainActor
protocol InferenceEngine {
    /// Short human label, stamped onto benchmark runs so a JSON says which
    /// engine produced it. e.g. "llama.cpp · GPU (Metal)".
    var label: String { get }

    var isLoaded: Bool { get }

    /// Ensure the model is present and resident. `progress` reports a first-run
    /// download fraction (0...1); it never fires once the model is on disk.
    func ensureLoaded(progress: @escaping (Double) -> Void) async throws

    /// Free the model from memory.
    func unload()

    /// One-shot completion.
    func generate(prompt: String,
                  maxTokens: Int,
                  onPartial: @escaping (String) -> Void) async throws -> String

    /// Completion against a cached shared prefix plus a short per-call suffix.
    ///
    /// This is the contract that makes scoring 16 criteria viable at all: the
    /// prefix (examiner instructions + the transcript) is processed ONCE and its
    /// state reused by every later call sharing it, so each criterion only pays
    /// for its own short question. Measured on-device with llama.cpp: criterion 1
    /// pays the transcript prefill (~18.6s), criteria 2+ are decode-mostly
    /// (~7.3s) — that gap is the cache earning its keep.
    ///
    /// A backend that cannot reuse a prefix MUST still return output identical to
    /// `generate(prompt: sharedPrefix + suffix)` — only the cost may differ.
    func generate(sharedPrefix: String,
                  suffix: String,
                  maxTokens: Int,
                  onPartial: @escaping (String) -> Void) async throws -> String
}

enum InferenceError: Error, LocalizedError {
    case notLoaded
    var errorDescription: String? { "Model not loaded." }
}
