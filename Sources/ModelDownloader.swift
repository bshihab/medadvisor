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
    /// Raw last status from the download daemon (diagnostic, shown in Settings) —
    /// surfaces waiting/paused/failed states that would otherwise look like a
    /// silent 0%.
    @Published private(set) var statusDetail: String?

    var isDownloaded: Bool { isReady }

    /// Resolved on-disk path to the model file, cached once available.
    private var resolvedModelPath: String?

    // Live Activity (Lock Screen / Dynamic Island) for the download.
    private var activity: Activity<ModelDownloadAttributes>?
    private var lastActivityProgress: Double = -1

    /// Launch-time sync: the OS may have finished (or progressed) the asset-pack
    /// download while the app wasn't running — the pack has a *prefetch* policy,
    /// so iOS starts downloading it right after install, before first launch.
    func resume() {
        Task {
            await refreshInstalledState()
            if self.isReady {
                await MainActor.run { self.endActivity(finished: true) }  // clear stragglers
            } else {
                self.observeStatus()   // a prefetch may be mid-flight — show its progress
            }
        }
    }

    /// Single shared observer of the pack's download status. Feeds the in-app
    /// progress bar and the Live Activity from whatever download is in flight
    /// (prefetch or user-initiated).
    private var statusTask: Task<Void, Never>?

    private func observeStatus() {
        guard statusTask == nil else { return }
        statusTask = Task { [assetPackID] in
            for await update in AssetPackManager.shared.statusUpdates(forAssetPackWithID: assetPackID) {
                if case .downloading(_, let p) = update {
                    await MainActor.run {
                        self.isDownloading = true
                        self.progress = p.fractionCompleted
                        self.statusDetail = nil          // bytes flowing — no diagnosis needed
                        if self.activity == nil { self.startActivity() }
                        self.updateActivity(p.fractionCompleted)
                    }
                } else {
                    // Any non-downloading state (waiting, paused, failed, …):
                    // surface it verbatim so a stall is never a silent 0%.
                    let desc = String(describing: update)
                    print("[ModelDownloader] status: \(desc)")
                    await MainActor.run { self.statusDetail = desc }
                }
            }
        }
    }

    private func stopObserving() {
        statusTask?.cancel()
        statusTask = nil
    }

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

            // Progress flows through the shared status observer while
            // ensureLocalAvailability drives the download to completion.
            observeStatus()
            try await AssetPackManager.shared.ensureLocalAvailability(of: pack)
            stopObserving()

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
            stopObserving()
            await MainActor.run {
                self.isDownloading = false
                self.errorMessage = "Model download failed: \(error.localizedDescription)"
                self.endActivity(finished: false)
            }
        }
    }

    /// Tear down whatever download session exists (wedged prefetch sessions
    /// "begin" but never transfer) and issue a fresh user-initiated request.
    func restartDownload() {
        Task {
            self.stopObserving()
            try? await AssetPackManager.shared.remove(assetPackWithID: assetPackID)
            await MainActor.run {
                self.progress = 0
                self.errorMessage = nil
                self.statusDetail = nil
            }
            await self.runDownload()
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
        // The file's in-pack path depends on how ba-package stored the selector
        // (repo-root-relative vs manifest-dir-relative) — try both spellings.
        let candidates = [
            modelAssetPath,                                    // ModelAssets/Qwen….gguf
            "Contents/" + modelAssetPath,                      // as stored in the .aar
            (modelAssetPath as NSString).lastPathComponent,    // Qwen….gguf
        ]
        for path in candidates {
            guard let descriptor = try? AssetPackManager.shared.descriptor(for: FilePath(path)) else { continue }
            defer { try? descriptor.close() }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            if fcntl(descriptor.rawValue, F_GETPATH, &buffer) != -1 {
                return String(cString: buffer)
            }
        }
        throw NSError(domain: "ModelDownloader", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Couldn't resolve the model file inside the asset pack."])
    }

    // MARK: - Live Activity

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // End any activity left over from a previous process — updating a
        // reattached activity after force-quit proved unreliable (it renders
        // frozen), so always start fresh.
        for stale in Activity<ModelDownloadAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        activity = nil
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
