import Foundation

/// The GGUF language models the app can run, and everything that differs
/// between them. Adding a model means adding a case here — nothing else in the
/// download or inference path is model-aware.
///
/// **Qwen 2.5-7B is and stays the default.** A second model is selectable so it
/// can be evaluated on real consultations before any switch is considered; the
/// benchmarks that motivated it measure agreement with authored labels, not
/// clinical correctness, so the director's judgement is the deciding evidence.
/// See tools/llm-benchmark/MODEL-COMPARISON.md.
///
/// Switching is non-destructive: each model has its own filename, so a model
/// already on disk is never touched by selecting or downloading another one.
enum LLMModel: String, CaseIterable, Identifiable, Sendable {
    case qwen25_7B
    case qwen35_4B

    var id: String { rawValue }

    /// The default, and what every existing install already has.
    static let fallback: LLMModel = .qwen25_7B

    private static let selectedKey = "selectedLLMModel"

    /// Which model the engine uses. Changing this unloads the engine so the next
    /// generation picks up the new weights (see `LLMEngine.selectModel`).
    static var selected: LLMModel {
        get {
            guard let raw = UserDefaults.standard.string(forKey: selectedKey),
                  let m = LLMModel(rawValue: raw) else { return fallback }
            return m
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: selectedKey) }
    }

    var title: String {
        switch self {
        case .qwen25_7B: return "Qwen 2.5-7B"
        case .qwen35_4B: return "Qwen 3.5-4B"
        }
    }

    /// Shown under the title in Settings — plain language, no benchmark jargon.
    var blurb: String {
        switch self {
        case .qwen25_7B: return "Current model — the one your feedback has always used."
        case .qwen35_4B: return "Newer and smaller. Still being evaluated — treat its feedback as provisional."
        }
    }

    var fileName: String {
        switch self {
        case .qwen25_7B: return "Qwen2.5-7B-Instruct-Q4_K_M.gguf"
        case .qwen35_4B: return "Qwen3.5-4B-Q4_K_M.gguf"
        }
    }

    /// Tried in order: R2 primary (fast, free egress), HuggingFace as fallback.
    /// The file is byte-identical across mirrors so a resume may switch mid-file.
    var mirrors: [URL] {
        switch self {
        case .qwen25_7B:
            return [
                URL(string: "https://pub-911d7a5254944de984f1c95e6b8ddcdd.r2.dev/Qwen2.5-7B-Instruct-Q4_K_M.gguf")!,
                URL(string: "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf")!,
            ]
        case .qwen35_4B:
            return [
                URL(string: "https://pub-911d7a5254944de984f1c95e6b8ddcdd.r2.dev/Qwen3.5-4B-Q4_K_M.gguf")!,
                URL(string: "https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF/resolve/main/Qwen_Qwen3.5-4B-Q4_K_M.gguf")!,
            ]
        }
    }

    /// Human-readable, for the Settings row and the download button.
    var approxSize: String {
        switch self {
        case .qwen25_7B: return "~4.3 GB"
        case .qwen35_4B: return "~3.0 GB"
        }
    }

    /// Free space required before starting, with headroom for the .partial file.
    var bytesNeeded: Int64 {
        switch self {
        case .qwen25_7B: return 5_000_000_000
        case .qwen35_4B: return 4_000_000_000
        }
    }

    /// Expected SHA-256, lowercase hex. nil = not pinned → verification skipped
    /// with a loud log. Pin with: shasum -a 256 <file>
    ///
    /// Both mirrors serve byte-identical files, verified before pinning: the R2
    /// object and HuggingFace's x-linked-etag report the same digest and the same
    /// 3_013_027_808 bytes. That matters because the downloader may resume across
    /// mirrors mid-file, so a digest that held for only one of them would fail
    /// intermittently and look like a network fault.
    var expectedSHA256: String? {
        switch self {
        // TODO(Bilal): pin the 7B too — run `shasum -a 256` on the R2 object and
        // confirm HuggingFace's x-linked-etag matches before filling this in.
        case .qwen25_7B: return nil
        case .qwen35_4B:
            return "13c16f426047e2de38cd075bdade4a7bcbc8c774384876f677740cda65f8a983"
        }
    }

    // MARK: - Prompt format

    /// The assistant turn that opens generation.
    ///
    /// Qwen3/3.5 are **reasoning** models: left alone they emit a long thinking
    /// block and blow the per-criterion token budget before answering — measured
    /// on Qwen3.5-4B, it labeled 1 of 21 utterances and scored 0% recall.
    /// Pre-filling an EMPTY think block is the documented way to suppress that,
    /// and it is purely textual: it needs no llama.cpp flag, no Jinja template
    /// support, and no minimum runtime version, because this app builds ChatML
    /// itself. Qwen2.5 has no thinking mode and must NOT get the block.
    var assistantOpening: String {
        switch self {
        case .qwen25_7B: return "<|im_start|>assistant\n"
        case .qwen35_4B: return "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        }
    }
}
