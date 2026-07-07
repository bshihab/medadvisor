import Foundation
import ActivityKit
import BackgroundAssets
import System   // FileDescriptor

/// Delivers the Qwen2.5-7B-Instruct GGUF (~4.3 GB) as an **Apple-hosted managed
/// Background Assets pack** (iOS 26). Apple hosts it on their CDN (fast, free) and
/// the OS downloads it out-of-process — so it survives backgrounding, locking,
/// and force-quit, with no URLSession plumbing on our side.
///
/// Keeps the old `ModelDownloader.shared` name + interface (`isDownloaded`,
/// `progress`, `isDownloading`, `startDownload()`, `ensureModel()`) so callers
/// (LLMEngine, Settings, ModelManager) are unchanged.
///
/// VERIFY ON DEVICE (new iOS 26 API — shake these out on the Air / via ba-serve):
///  • `AssetPackManager` method/enum shapes (statusUpdates cases, descriptor type).
///  • The descriptor→path bridge (`fcntl(F_GETPATH)`): if the sandbox blocks
///    llama.cpp from opening the asset path directly, fall back to loading from
///    the file descriptor or from `contents(at:)` (memory-mapped Data).
final class ModelDownloader: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = ModelDownloader()
    private override init() {
        super.init()
        Task { await refreshInstalledState() }
    }

    /// Matches `ModelAssets/Manifest.json`.
    private let assetPackID = "qwen7b-q4"
    /// In-pack path == the manifest `fileSelectors` path (repo-root-relative when
    /// packaged with `ba-package`).
    private let modelAssetPath = "ModelAssets/Qwen2.5-7B-Instruct-Q4_K_M.gguf"

    /// Live state (observed by Settings).
    @Published private(set) var progress: Double = 0
    @Published private(set) var isDownloading = false
    @Published private(set) var errorMessage: String?
    /// Whether the pack is downloaded and locally available.
    @Published private(set) var isReady = false

    var isDownloaded: Bool { isReady }

    /// Resolved on-disk path to the model file, cached once available.
    private var resolvedModelPath: String?

    // Live Activity (Lock Screen / Dynamic Island) for the download.
    private var activity: Activity<ModelDownloadAttributes>?
    private var lastActivityProgress: Double = -1

    /// Launch-time sync: the OS may have finished (or progressed) the asset-pack
    /// download while the app wasn't running.
    func resume() { Task { await refreshInstalledState() } }

    // MARK: - State

    /// Probe whether the pack is already downloaded (best-effort). If a resolvable
    /// file descriptor exists, it's available.
    private func refreshInstalledState() async {
        if let path = try? await resolveModelPath() {
            await MainActor.run {
                self.resolvedModelPath = path
                self.isReady = true
                self.progress = 1
            }
        }
    }

    // MARK: - Download (from Settings)

    /// Ask the OS to download the asset pack, streaming progress to the UI + Live
    /// Activity. No-op if it's already available.
    func startDownload() {
        guard !isReady else { return }
        Task { await runDownload() }
    }

    private func runDownload() async {
        await MainActor.run {
            self.isDownloading = true
            self.errorMessage = nil
            self.progress = 0
            self.startActivity()
        }
        do {
            let pack = try await AssetPackManager.shared.assetPack(withID: assetPackID)

            // Observe progress on a child task while ensureLocalAvailability drives
            // the actual download to completion.
            let progressTask = Task { [assetPackID] in
                for await update in AssetPackManager.shared.statusUpdates(forAssetPackWithID: assetPackID) {
                    // VERIFY: exact case shape. WWDC showed `.downloading(_, progress)`
                    // where `progress` is a Foundation `Progress`.
                    if case .downloading(_, let p) = update {
                        await MainActor.run {
                            self.progress = p.fractionCompleted
                            self.updateActivity(p.fractionCompleted)
                        }
                    }
                }
            }

            try await AssetPackManager.shared.ensureLocalAvailability(of: pack)
            progressTask.cancel()

            let path = try await resolveModelPath()
            await MainActor.run {
                self.resolvedModelPath = path
                self.isReady = true
                self.isDownloading = false
                self.progress = 1
                self.endActivity(finished: true)
                Task { @MainActor in ModelManager.shared.modelChanged() }
            }
        } catch {
            await MainActor.run {
                self.isDownloading = false
                self.errorMessage = "Model download failed: \(error.localizedDescription)"
                self.endActivity(finished: false)
            }
        }
    }

    /// Remove the asset pack (Settings → Delete).
    func delete() {
        Task {
            try? await AssetPackManager.shared.remove(assetPackWithID: assetPackID)
            await MainActor.run {
                self.isReady = false
                self.progress = 0
                self.resolvedModelPath = nil
                ModelManager.shared.modelChanged()
            }
        }
    }

    // MARK: - Model access for llama.cpp

    /// For the LLM engine: ensure the pack is present and return a file URL whose
    /// path can be handed to llama.cpp. Downloads if missing.
    func ensureModel(onProgress: @escaping (Double) -> Void = { _ in }) async throws -> URL {
        if !isReady { await runDownload() }
        var path = resolvedModelPath
        if path == nil { path = try? await resolveModelPath() }
        guard isReady, let path else {
            throw NSError(domain: "ModelDownloader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The AI model isn't available yet. Download it in Settings."])
        }
        return URL(fileURLWithPath: path)
    }

    /// Bridge Background Assets → a filesystem path llama.cpp can mmap: open the
    /// asset's descriptor and recover its on-disk path via `fcntl(F_GETPATH)`.
    /// llama.cpp re-opens the path itself, so we can close our descriptor.
    private func resolveModelPath() async throws -> String {
        let descriptor = try AssetPackManager.shared.descriptor(for: FilePath(modelAssetPath))
        defer { try? descriptor.close() }
        let raw = descriptor.rawValue
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(raw, F_GETPATH, &buffer) != -1 else {
            throw NSError(domain: "ModelDownloader", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't resolve the model file path."])
        }
        return String(cString: buffer)
    }

    // MARK: - Live Activity

    private func reconcileActivities() {
        let all = Activity<ModelDownloadAttributes>.activities
        guard let first = all.first else { return }
        activity = first
        lastActivityProgress = -1
        for extra in all.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        reconcileActivities()
        guard activity == nil else { return }
        let state = ModelDownloadAttributes.ContentState(progress: 0, finished: false)
        let content = ActivityContent(state: state, staleDate: nil)
        activity = try? Activity.request(attributes: ModelDownloadAttributes(), content: content)
        lastActivityProgress = 0
    }

    private func updateActivity(_ p: Double) {
        guard let activity, p - lastActivityProgress >= 0.02 else { return }
        lastActivityProgress = p
        let state = ModelDownloadAttributes.ContentState(progress: p, finished: false)
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func endActivity(finished: Bool) {
        let all = Activity<ModelDownloadAttributes>.activities
        guard !all.isEmpty else { activity = nil; return }
        activity = nil
        let state = ModelDownloadAttributes.ContentState(
            progress: finished ? 1 : max(0, lastActivityProgress), finished: finished)
        let content = ActivityContent(state: state, staleDate: nil)
        Task {
            for a in all {
                await a.update(content)
                await a.end(content, dismissalPolicy: .after(Date().addingTimeInterval(4)))
            }
        }
    }
}
