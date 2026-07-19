import Foundation
import UIKit

/// Dev-only benchmark recorder for the on-device analysis pipeline.
///
/// Off by default. When "Record benchmark" is on in Settings, the next full
/// analysis is instrumented — generation throughput, per-stage timings, peak
/// memory, the thermal-state curve, and battery drain — then written to a
/// shareable JSON file in Documents. These are the real numbers behind the
/// on-device story (and the "iOS 26 baseline" column for the write-up).
///
/// Everything here is a no-op unless the toggle is on, so the director's build
/// and normal use are completely unaffected. The engine label is passed in, so
/// the same recorder will measure the Core AI path later just by changing it.
@MainActor
final class BenchmarkRecorder: ObservableObject {
    static let shared = BenchmarkRecorder()
    private init() {}

    static let defaultsKey = "benchmarkEnabled"

    /// Last completed run — drives the Settings summary + export button.
    @Published private(set) var lastReport: Report?
    @Published private(set) var lastReportURL: URL?

    /// Set by `markStage`; generations are attributed to whatever stage is live.
    private(set) var currentPhase = "idle"

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.defaultsKey) }
    private var active: Run?
    private var sampleTimer: Timer?

    // MARK: - Recording lifecycle

    /// Begin a run. No-op unless the toggle is on. Call once per analysis.
    func begin(engine: String, criterionCount: Int) {
        sampleTimer?.invalidate(); sampleTimer = nil
        currentPhase = "idle"
        guard isEnabled else { active = nil; return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        active = Run(engine: engine,
                     start: Date(),
                     batteryStart: UIDevice.current.batteryLevel,
                     criterionCount: criterionCount)
        sample()   // t≈0 baseline sample
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    /// Mark the start of a pipeline stage (transcribing, scoring, …).
    func markStage(_ name: String) {
        currentPhase = name
        guard var run = active else { return }
        run.stages.append(Stage(name: name, at: elapsed()))
        active = run
    }

    /// Record how long loading the model into memory took (first analysis only).
    func recordLoad(seconds: Double) {
        guard var run = active else { return }
        run.loadSeconds = seconds
        active = run
    }

    /// Record one LLM generation call's token count and wall time. The call's
    /// START offset is back-computed from its duration so throughput can be
    /// plotted against elapsed time — a sagging curve is thermal throttling.
    /// `cachedInputTokens` is Core AI only (llama.cpp doesn't report it): how many
    /// input tokens came from the prefix KV cache instead of being reprocessed.
    /// Across the 16 criteria it should be roughly the transcript length — if it
    /// stays near zero, prefix caching isn't working and the design is wrong.
    func recordGeneration(phase: String, tokens: Int, seconds: Double,
                          cachedInputTokens: Int? = nil) {
        guard var run = active else { return }
        let at = max(0, elapsed() - seconds)
        run.generations.append(Generation(phase: phase, at: at, tokens: tokens,
                                          seconds: seconds,
                                          cachedInputTokens: cachedInputTokens))
        active = run
    }

    /// Finish the run, compute aggregates, and write the JSON. No-op if inactive.
    func end(success: Bool) {
        guard let run = active else { return }
        sampleTimer?.invalidate(); sampleTimer = nil
        active = nil
        currentPhase = "idle"

        let totalSeconds = Date().timeIntervalSince(run.start)
        let genTokens = run.generations.reduce(0) { $0 + $1.tokens }
        let genSeconds = run.generations.reduce(0) { $0 + $1.seconds }
        let batteryEnd = UIDevice.current.batteryLevel
        // -1 when unavailable (Simulator) or if the level rose (charging).
        let batteryDrop = (run.batteryStart >= 0 && batteryEnd >= 0)
            ? Double(run.batteryStart - batteryEnd) * 100 : -1
        let peakThermal = run.thermalSamples.map(\.state).max() ?? 0

        let report = Report(
            engine: run.engine,
            device: Self.deviceModel(),
            osVersion: UIDevice.current.systemVersion,
            success: success,
            criterionCount: run.criterionCount,
            totalSeconds: totalSeconds,
            modelLoadSeconds: run.loadSeconds,
            tokensGenerated: genTokens,
            tokensPerSecond: genSeconds > 0 ? Double(genTokens) / genSeconds : 0,
            peakMemoryMB: run.peakFootprintMB,
            peakThermal: Self.thermalName(peakThermal),
            batteryPercentUsed: batteryDrop,
            stages: run.stages.map { .init(name: $0.name, atSeconds: $0.at) },
            generations: run.generations.map { .init(phase: $0.phase, atSeconds: $0.at, tokens: $0.tokens, seconds: $0.seconds, cachedInputTokens: $0.cachedInputTokens) },
            thermalCurve: run.thermalSamples.map { .init(atSeconds: $0.at, state: Self.thermalName($0.state)) },
            recordedAt: ISO8601DateFormatter().string(from: Date()))

        lastReport = report
        lastReportURL = Self.write(report)
    }

    /// One-line human summary of the most recent run.
    var lastSummaryText: String? { lastReport.map(Self.summaryText) }

    /// Compact one-liner for any run:
    /// "3.5 tok/s · 211s total · 495 MB peak · fair · 5.0% batt"
    static func summaryText(_ r: Report) -> String {
        let batt = r.batteryPercentUsed >= 0
            ? String(format: "%.1f%% batt", r.batteryPercentUsed) : "batt n/a"
        return String(format: "%.1f tok/s · %.0fs total · %.0f MB peak · %@ · %@",
                      r.tokensPerSecond, r.totalSeconds, r.peakMemoryMB, r.peakThermal, batt)
    }

    // MARK: - Saved runs

    struct SavedRun: Identifiable {
        let id: URL
        let report: Report
        var url: URL { id }
    }

    /// Every benchmark JSON on disk, newest first. Each analysis writes its own
    /// file, so back-to-back stress runs are all here — not just the latest.
    func savedRuns() -> [SavedRun] {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.lastPathComponent.hasPrefix("benchmark-") && $0.pathExtension == "json" }
            .compactMap { url -> SavedRun? in
                guard let data = try? Data(contentsOf: url),
                      let report = try? decoder.decode(Report.self, from: data) else { return nil }
                return SavedRun(id: url, report: report)
            }
            .sorted { $0.report.recordedAt > $1.report.recordedAt }
    }

    func deleteAllSavedRuns() {
        for run in savedRuns() { try? FileManager.default.removeItem(at: run.url) }
        lastReport = nil
        lastReportURL = nil
    }

    /// "Jul 18 · 18:42:04" from the stored ISO timestamp (falls back to the
    /// raw string). Includes the day: runs accumulate across sessions and a
    /// bare clock time is ambiguous after the first day.
    static func displayTime(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d · HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: - Sampling

    private func sample() {
        guard var run = active else { return }
        let mb = Double(Self.footprintBytes()) / 1_048_576
        run.peakFootprintMB = max(run.peakFootprintMB, mb)
        run.thermalSamples.append(
            ThermalSample(at: elapsed(), state: ProcessInfo.processInfo.thermalState.rawValue))
        active = run
    }

    private func elapsed() -> Double {
        guard let start = active?.start else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - In-flight run (value type, mutated through `active`)

    private struct Run {
        let engine: String
        let start: Date
        let batteryStart: Float
        let criterionCount: Int
        var stages: [Stage] = []
        var generations: [Generation] = []
        var thermalSamples: [ThermalSample] = []
        var loadSeconds: Double = 0
        var peakFootprintMB: Double = 0
    }
    private struct Stage { let name: String; let at: Double }        // seconds since start
    private struct Generation { let phase: String; let at: Double; let tokens: Int; let seconds: Double; let cachedInputTokens: Int? }
    private struct ThermalSample { let at: Double; let state: Int }  // 0 nominal … 3 critical

    // MARK: - Report (Codable → JSON on disk)

    struct Report: Codable {
        let engine: String
        let device: String
        let osVersion: String
        let success: Bool
        let criterionCount: Int
        let totalSeconds: Double
        let modelLoadSeconds: Double
        let tokensGenerated: Int
        let tokensPerSecond: Double
        let peakMemoryMB: Double
        let peakThermal: String
        let batteryPercentUsed: Double   // -1 if unavailable (e.g. Simulator)
        let stages: [StageOut]
        let generations: [GenerationOut]
        let thermalCurve: [ThermalOut]
        let recordedAt: String

        struct StageOut: Codable { let name: String; let atSeconds: Double }
        struct GenerationOut: Codable { let phase: String; let atSeconds: Double; let tokens: Int; let seconds: Double; let cachedInputTokens: Int? }
        struct ThermalOut: Codable { let atSeconds: Double; let state: String }
    }

    // MARK: - Helpers

    private static func write(_ report: Report) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report),
              let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        let url = dir.appendingPathComponent("benchmark-\(Int(Date().timeIntervalSince1970)).json")
        try? data.write(to: url)
        return url
    }

    private static func thermalName(_ raw: Int) -> String {
        switch raw {
        case 0:  return "nominal"
        case 1:  return "fair"
        case 2:  return "serious"
        case 3:  return "critical"
        default: return "unknown"
        }
    }

    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { id, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            id.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    /// The app's physical footprint — the metric iOS compares against its limit.
    private static func footprintBytes() -> UInt64 {
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
}
