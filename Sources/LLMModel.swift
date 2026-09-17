import Foundation

/// The GGUF language model the app runs, and everything the download and
/// inference paths need to know about it. Adding a model means adding a case
/// here and switching the properties below on it — nothing else in the
/// download or inference path is model-aware.
///
/// **Qwen 3.5-4B is the only model** (since 2026-09-17). Qwen 2.5-7B, the
/// original default, was removed: every judge-quality measurement since August
/// is on the 4B — it beat the 7B on the 240-decision set (85.4% vs 79.2%,
/// tools/llm-benchmark/MODEL-COMPARISON.md) and all calibration work
/// (calibration/FINDINGS.md) ran on it; the 7B was never run on the
/// calibration gold. The director's gold scores are still the clinical check.
///
/// An upgraded install: `ModelDownloader.sweepRetiredModels` deletes the 7B's
/// file once at launch, and a stored selection naming the retired case decodes
/// to `fallback` (see `selected`) — `qwen25_7B` is no longer a raw value, so
/// `LLMModel(rawValue:)` returns nil for it rather than trapping.
enum LLMModel: String, CaseIterable, Identifiable, Sendable {
    case qwen35_4B

    var id: String { rawValue }

    /// The default, and today the only case. An install that has never
    /// downloaded it fetches it at the next launch on Wi-Fi
    /// (ModelDownloader.resume, once the user has opted in).
    static let fallback: LLMModel = .qwen35_4B

    private static let selectedKey = "selectedLLMModel"

    /// Which model the engine uses. Changing this unloads the engine so the next
    /// generation picks up the new weights (see `LLMEngine.selectModel`).
    /// A stored value that is not a current case (the retired `qwen25_7B`)
    /// reads as `fallback`.
    static var selected: LLMModel {
        get {
            guard let raw = UserDefaults.standard.string(forKey: selectedKey),
                  let m = LLMModel(rawValue: raw) else { return fallback }
            return m
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: selectedKey) }
    }

    /// Clear a stored selection that names a model this build no longer has,
    /// so the console says so once instead of `selected` deciding silently on
    /// every read. Called from the launch sweep.
    static func dropRetiredSelection() {
        guard let raw = UserDefaults.standard.string(forKey: selectedKey),
              LLMModel(rawValue: raw) == nil else { return }
        UserDefaults.standard.removeObject(forKey: selectedKey)
        print("[LLMModel] Stored selection '\(raw)' is no longer a model — using \(fallback.title).")
    }

    var title: String { "Qwen 3.5-4B" }

    /// Shown under the title in Settings — plain language, no benchmark jargon.
    var blurb: String { "The model that grades your feedback." }

    var fileName: String { "Qwen3.5-4B-Q4_K_M.gguf" }

    /// Tried in order: R2 primary (fast, free egress), HuggingFace as fallback.
    /// The file is byte-identical across mirrors so a resume may switch mid-file.
    var mirrors: [URL] {
        [
            URL(string: "https://pub-911d7a5254944de984f1c95e6b8ddcdd.r2.dev/Qwen3.5-4B-Q4_K_M.gguf")!,
            URL(string: "https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF/resolve/main/Qwen_Qwen3.5-4B-Q4_K_M.gguf")!,
        ]
    }

    /// Human-readable, for the Settings row and the download button.
    var approxSize: String { "~3.0 GB" }

    /// Free space required before starting, with headroom for the .partial file.
    var bytesNeeded: Int64 { 4_000_000_000 }

    /// Expected SHA-256, lowercase hex. nil = not pinned → verification skipped
    /// with a loud log. Pin with: shasum -a 256 <file>
    ///
    /// Both mirrors serve byte-identical files, verified before pinning: the R2
    /// object and HuggingFace's x-linked-etag report the same digest and the same
    /// 3_013_027_808 bytes. That matters because the downloader may resume across
    /// mirrors mid-file, so a digest that held for only one of them would fail
    /// intermittently and look like a network fault. Re-pin from both sources
    /// if the model is ever re-quantized.
    var expectedSHA256: String? {
        "13c16f426047e2de38cd075bdade4a7bcbc8c774384876f677740cda65f8a983"
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
    /// itself. (A model without a thinking mode, like the retired Qwen2.5,
    /// must NOT get the block.)
    var assistantOpening: String { "<|im_start|>assistant\n<think>\n\n</think>\n\n" }
}
