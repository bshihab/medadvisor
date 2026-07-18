import Foundation

// The Core AI runtime is vendored at Vendor/coreai-models (pinned upstream
// 04a3fd6 + local patches — see Vendor/coreai-models/VENDORED.md), so this
// whole file compiles out until that dependency is added. Keeps the branch
// buildable while the model export is still being figured out.
#if canImport(CoreAILanguageModels)
import FoundationModels
import CoreAILanguageModels
import CoreAIShared   // CLILogger — the engine's own load-progress logging
import CoreAI         // AIModel / AIModelCache / SpecializationOptions (SDK)
import os

/// The Core AI models this build knows how to bundle, in priority order.
///
/// Which one actually loads: the `coreAIModelFolder` UserDefaults key if it
/// names an installed folder (set from Settings → Developer), else the first
/// entry whose folder reference made it into the app bundle. The 4B leads —
/// it's the only Core AI model that could matter for product quality; the
/// 0.6B is an instrumentation vehicle for measuring the framework itself.
///
/// A folder may hold the raw export (`<name>.aimodel`) or an ahead-of-time
/// compiled `<name>.<arch>.aimodelc` (from `xcrun coreai-build compile`) —
/// for the AOT case, metadata.json's `assets.main` must be edited to the
/// compiled filename, and the arch must match this device
/// (`AIModel.deviceArchitectureName`, printed at every load).
enum CoreAIModelCatalog {
    struct Entry: Identifiable, Equatable {
        let folder: String
        let displayName: String
        let approxSize: String
        var id: String { folder }
    }

    static let all: [Entry] = [
        Entry(folder: "qwen3_4b_mixed_4bit_8bit_static",
              displayName: "Qwen3-4B", approxSize: "~2.4 GB"),
        Entry(folder: "qwen3_0_6b_mixed_4bit_8bit_static",
              displayName: "Qwen3-0.6B", approxSize: "~450 MB"),
    ]

    /// UserDefaults key for the dev override ("" = automatic priority order).
    /// Read at load time, so switching models needs an app relaunch — same
    /// contract as the engine picker.
    static let selectionKey = "coreAIModelFolder"

    static var installed: [Entry] { all.filter { bundleURL(of: $0) != nil } }

    static var active: Entry? {
        if let sel = UserDefaults.standard.string(forKey: selectionKey), !sel.isEmpty,
           let chosen = installed.first(where: { $0.folder == sel }) {
            return chosen
        }
        return installed.first
    }

    static func bundleURL(of entry: Entry) -> URL? {
        Bundle.main.url(forResource: entry.folder, withExtension: nil)
    }
}

/// Core AI backend (iOS 27+): an Apple-optimized Qwen3 exported to `.aimodel`,
/// run through FoundationModels' `LanguageModelSession`.
///
/// The point of this engine is to answer three questions with numbers:
///   1. Does a big model actually execute on the Neural Engine, or fall back to
///      the GPU? (`ComputeUnitKind.availableKinds` + specialization options)
///   2. Does throughput hold under sustained load, where llama.cpp on the GPU
///      degraded 31% / +53% wall-clock across three back-to-back sessions?
///   3. Does scoring quality survive the model change?
///
/// NOTE ON THE MODEL: Apple's iOS support table caps Qwen3 at **4B** — Qwen3-8B
/// is macOS-only, and the qwen2 recipe only covers Qwen2.5-1.5B. So there is no
/// Core AI equivalent of our Qwen2.5-7B on iPhone. This engine is therefore a
/// *newer, smaller* model on a *better chip* — not a like-for-like swap — which
/// is exactly why the rubric has to be re-validated before this could ship.
///
/// The export recipe (on an arm64 Mac — Apple ships the wheels for Apple
/// silicon only):
///
///     uv run coreai.llm.export Qwen/Qwen3-0.6B --platform iOS --output-dir ./my-models/
///
/// ⚠️ Do NOT pass --max-context-length 6144 (coreai-core 1.0.0b2): the flag is
/// stamped into metadata but the compiled artifact ships a fixed shape ladder
/// regardless — extend/prompt_opt at contexts {256,512,1024,2048,4096} ×
/// query {8,16,64}. Verified in the exporter source (ios.py doubles from 256
/// and never emits non-power-of-two rungs) and in the runtime
/// (CoreAIStaticShapeEngine requires an exact extend_<ctx> match). Real
/// context ceiling here: 4096, below LlamaContext's n_ctx=6144 — long
/// consultations get tight on this path and the writeup must note the
/// asymmetry.
///
/// The export emits a FOLDER, not a file — model + tokenizer together:
///
///     qwen3_0_6b_mixed_4bit_8bit_static/     <- resourcesAt: wants THIS
///       ├── metadata.json
///       ├── qwen3_0_6b_mixed_4bit_8bit_static.aimodel/ (main.mlirb, main.hash)
///       └── tokenizer/                                 (tokenizer.json, chat_template.jinja, …)
///
/// It must be added to the target as a **folder reference** (blue folder in
/// Xcode), not a group — a group flattens the subfolders and the tokenizer
/// lookup breaks.
@available(iOS 27.0, *)
@MainActor
final class CoreAIEngine: InferenceEngine {
    var label: String {
        "Core AI · \(CoreAIModelCatalog.active?.displayName ?? "no model bundled")"
    }
    let requiresManagedDownload = false   // model ships in the app bundle

    private var model: CoreAILanguageModel?

    var isLoaded: Bool { model != nil }

    func unload() { model = nil }

    func ensureLoaded(progress: @escaping (Double) -> Void) async throws {
        if model != nil { return }
        guard let active = CoreAIModelCatalog.active,
              let url = CoreAIModelCatalog.bundleURL(of: active) else {
            throw InferenceError.notLoaded
        }

        // ── Load instrumentation ────────────────────────────────────────────
        // Every line below exists because this stage has failed four different
        // ways (see the branch's commit log): silent 15-minute specialization,
        // jetsam mid-load that the 1s benchmark sampler never caught, and a
        // shape-ladder mismatch. Until the load path is boring, it logs.

        // The engine's own progress markers ("Preparing …", "Loaded N graphs",
        // "KV cache allocated: … bytes", "Engine initialized") are behind
        // CLILogger, which defaults to silent. Level 2 turns them all on —
        // this is what distinguishes "still compiling" from "wedged".
        CLILogger.setLevel(to: 2)

        DevLog.log("[CoreAI] loading \(active.folder)")
        // Names the .aimodelc architecture this phone needs — required to pick
        // which ahead-of-time-compiled artifact to bundle (h18-class for the
        // iPhone 17 family; exact string comes from this line).
        DevLog.log("[CoreAI] device architecture: \(AIModel.deviceArchitectureName)")
        DevLog.log(String(format: "[CoreAI] physical RAM %.0f MB · jetsam headroom now %.0f MB",
                     Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576,
                     Double(os_proc_available_memory()) / 1_048_576))
        logSpecializationCacheState(bundleURL: url)

        let watcher = Self.startLoadMemoryWatcher()
        defer { watcher.cancel() }

        // `.eager`, NOT the default `.lazy`: lazy defers the engine load (and,
        // on the first-ever run, minutes of one-time device specialization) to
        // the FIRST generation — which made speaker attribution look hung and
        // would mis-charge the load to attribution in the benchmark. Eager pays
        // it here, inside the stage EncounterProcessor already times as
        // preparingModel / modelLoadSeconds. Compare against llama.cpp's 14.0s.
        //
        // kvCacheStrategy is a NO-OP for iOS static-shape bundles — verified in
        // the vendored engine source: CoreAIStaticShapeEngine always allocates
        // full-context fp16 K+V IOSurfaces at init (~0.94 GB for the 0.6B,
        // ~1.2 GB for the 4B at 4096), whatever strategy is passed. The
        // .fixedSize→.auto change in a2b839c changed nothing; it's kept as
        // .auto only because that's the default.
        let t0 = Date()
        model = try await CoreAILanguageModel(
            resourcesAt: url,
            mode: .eager,
            kvCacheStrategy: .auto)
        DevLog.log(String(format: "[CoreAI] engine loaded in %.1fs", Date().timeIntervalSince(t0)))
    }

    /// Log whether the on-device specialization cache already holds this model
    /// — a MISS means the load is about to pay the full device compile.
    ///
    /// The runtime keys its cache on (asset URL, SpecializationOptions), and
    /// for an iOS chunked-static bundle it always specializes with preferred
    /// `.neuralEngine` (ModelStructure.specializationOptions in the vendored
    /// source) — so probe exactly that key. Best-effort: a probe failure only
    /// prints.
    private func logSpecializationCacheState(bundleURL: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: bundleURL, includingPropertiesForKeys: nil)) ?? []
        guard let asset = contents.first(where: {
            ["aimodel", "aimodelc"].contains($0.pathExtension.lowercased())
        }) else {
            DevLog.log("[CoreAI] ⚠️ no .aimodel/.aimodelc inside \(bundleURL.lastPathComponent)")
            return
        }
        DevLog.log("[CoreAI] model asset: \(asset.lastPathComponent)")
        do {
            let options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
            if try AIModelCache.default.model(for: asset, options: options) != nil {
                DevLog.log("[CoreAI] specialization cache: HIT — engine creation should be quick")
            } else {
                DevLog.log("[CoreAI] specialization cache: MISS — the device will specialize now."
                    + " This is the multi-minute compile: expect app storage to grow"
                    + " and ANECompilerService CPU in Console. If neither moves, it's wedged.")
            }
        } catch {
            DevLog.log("[CoreAI] specialization cache probe failed: \(error)")
        }
    }

    /// Delete every entry in the app's Core AI specialization cache. Forces a
    /// full re-specialization on the next load — the remedy for a poisoned
    /// cache (e.g. a load attempted against a partially-copied model) and the
    /// way to reclaim the multi-GB compiled artifacts without reinstalling.
    static func clearSpecializationCache() -> String {
        do {
            try AIModelCache.default.deleteAll()
            DevLog.log("[CoreAI] specialization cache cleared")
            return "Specialization cache cleared. Next load re-specializes from scratch."
        } catch {
            DevLog.log("[CoreAI] specialization cache clear FAILED: \(error)")
            return "Cache clear failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Load-time memory watcher

    /// Samples the app's physical footprint and remaining jetsam budget every
    /// 50ms while the engine loads, printing every 2s plus running extremes.
    /// Exists because the fatal allocation spike killed the process between
    /// the benchmark HUD's 1s samples — this catches it, and its last printed
    /// line before a jetsam IS the measurement.
    private static func startLoadMemoryWatcher() -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            var peakFootprint: UInt64 = 0
            var minHeadroom = UInt64.max
            var sinceLastPrint = 0
            while !Task.isCancelled {
                let footprint = Self.footprintBytes()
                let headroom = UInt64(os_proc_available_memory())
                peakFootprint = max(peakFootprint, footprint)
                minHeadroom = min(minHeadroom, headroom)
                sinceLastPrint += 1
                if sinceLastPrint >= 40 {   // ≈ every 2s at 50ms cadence
                    sinceLastPrint = 0
                    DevLog.log(String(format: "[CoreAI][mem] footprint %.0f MB (peak %.0f) · headroom %.0f MB (min %.0f)",
                                 Double(footprint) / 1_048_576, Double(peakFootprint) / 1_048_576,
                                 Double(headroom) / 1_048_576, Double(minHeadroom) / 1_048_576))
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            }
            DevLog.log(String(format: "[CoreAI][mem] load done · peak footprint %.0f MB · min headroom %.0f MB",
                         Double(peakFootprint) / 1_048_576, Double(minHeadroom) / 1_048_576))
        }
    }

    /// The app's physical footprint — the metric iOS jetsam compares against
    /// its limit (same as BenchmarkRecorder's, which is private there).
    private nonisolated static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    // MARK: - Generation

    func generate(prompt: String,
                  maxTokens: Int,
                  onPartial: @escaping (String) -> Void) async throws -> String {
        try await ensureLoaded(progress: { _ in })
        guard let model else { throw InferenceError.notLoaded }
        let session = LanguageModelSession(model: model)
        return try await respond(session: session, to: prompt,
                                 maxTokens: maxTokens, onPartial: onPartial)
    }

    /// The migration's make-or-break question, now with a known answer to
    /// verify on-device.
    ///
    /// The shared prefix (examiner instructions + transcript) becomes the
    /// session's `instructions`. A *fresh session per criterion* keeps the 16
    /// criteria independent — one long-lived session would let criterion 1's
    /// answer pollute criterion 2's context and grow the prompt every call.
    ///
    /// What the vendored engine source says will happen: ALL Core AI engines
    /// (static/sequential/pipelined) full-reset their KV cache when a request
    /// diverges from the previous one ("partial rewind corrupts buffer
    /// rotation") — and criterion N+1 diverges from criterion N right after
    /// the shared prefix. So expect `cachedInputTokens` ≈ 0 on every criterion
    /// and per-criterion wall time ≈ criterion 1 (full transcript re-prefill,
    /// 16 times) — where llama.cpp measured 18.6s for criterion 1 and 7.3s
    /// after. The number below is patched (VENDORED.md) to report the reuse
    /// honestly; if it comes back ≈ transcript length AND criteria 2+ are
    /// fast, Apple shipped real prefix reuse and this comment dies happy.
    func generate(sharedPrefix: String,
                  suffix: String,
                  maxTokens: Int,
                  onPartial: @escaping (String) -> Void) async throws -> String {
        try await ensureLoaded(progress: { _ in })
        guard let model else { throw InferenceError.notLoaded }
        let session = LanguageModelSession(model: model, instructions: sharedPrefix)
        return try await respond(session: session, to: suffix,
                                 maxTokens: maxTokens, onPartial: onPartial)
    }

    private func respond(session: LanguageModelSession,
                         to prompt: String,
                         maxTokens: Int,
                         onPartial: @escaping (String) -> Void) async throws -> String {
        let options = GenerationOptions(maximumResponseTokens: maxTokens)
        let t0 = Date()
        let response = try await session.respond(to: prompt, options: options)
        let text = response.content
        onPartial(text)

        // Exact token counts, straight from the framework — better than
        // llama.cpp's piece-counting, and directly comparable.
        let usage = response.usage
        BenchmarkRecorder.shared.recordGeneration(
            phase: BenchmarkRecorder.shared.currentPhase,
            tokens: usage.output.totalTokenCount,
            seconds: Date().timeIntervalSince(t0),
            cachedInputTokens: usage.input.cachedTokenCount)

        DevLog.log("[CoreAI] in=\(usage.input.totalTokenCount) cached=\(usage.input.cachedTokenCount) out=\(usage.output.totalTokenCount)")
        return text
    }
}

#endif
