import Foundation
import ActivityKit
import UIKit
import CryptoKit

/// Downloads the Qwen2.5-7B GGUF (~4.4 GB) directly over HTTPS with **byte-range
/// resume**: bytes stream into `Documents/<name>.partial`, so any interruption —
/// force-quit, reboot, network drop — resumes from the exact byte next time.
/// Mirrors are tried in order (Cloudflare R2 primary, HuggingFace fallback); the
/// file is identical on every mirror, so a resume can switch mirrors mid-file.
///
/// Chosen over Apple-hosted Background Assets after its daemon proved unreliable
/// in practice (downloads that never start or park on lock, progress destroyed by
/// force-quit, TestFlight-only testing) — see README "Model delivery". The BA
/// packaging lives on in ModelAssets/ + MODEL-ASSETS.md for a future revisit.
final class ModelDownloader: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = ModelDownloader()
    private override init() { super.init() }

    /// Tried in order on failure: Cloudflare R2 (fast, free egress) first,
    /// HuggingFace as the fallback mirror (throttled but always there).
    private let mirrors = [
        URL(string: "https://pub-911d7a5254944de984f1c95e6b8ddcdd.r2.dev/Qwen2.5-7B-Instruct-Q4_K_M.gguf")!,
        URL(string: "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf")!,
    ]
    private let fileName = "Qwen2.5-7B-Instruct-Q4_K_M.gguf"

    /// Expected SHA-256 of the GGUF, lowercase hex. When set, a completed
    /// download is verified before it's accepted — this is the supply-chain
    /// guard: a re-uploaded/tampered mirror, or a cross-mirror resume splice,
    /// can't hand a corrupt or malicious 4.3 GB blob to llama.cpp (which then
    /// processes PHI). nil = NOT PINNED YET → verification is skipped with a
    /// loud log. TODO(Bilal): pin this. Compute once on the built file:
    ///   shasum -a 256 Qwen2.5-7B-Instruct-Q4_K_M.gguf
    private static let expectedSHA256: String? = nil

    /// Live download state (observed by Settings).
    @Published private(set) var progress: Double = 0
    @Published private(set) var isDownloading = false {
        // Keep the screen awake while downloading (main thread — all writes to
        // isDownloading happen there): the user can set the phone down for the
        // ~10 minutes without auto-lock suspending the transfer.
        didSet { UIApplication.shared.isIdleTimerDisabled = isDownloading }
    }
    @Published private(set) var errorMessage: String?

    private static let userDeletedKey = "modelDeletedByUser"
    private static let expectedTotalKey = "modelExpectedTotalBytes"
    // The user must opt in once (first-run disclosure) before the ~4.4GB model
    // auto-downloads — it no longer starts silently at first launch.
    private static let optedInKey = "modelDownloadOptedIn"

    // Transfer state (touched only on the session's serial delegate queue).
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var baseOffset: Int64 = 0          // bytes already on disk when this attempt started
    private var received: Int64 = 0            // bytes received during this attempt
    private var totalBytes: Int64 = 0          // full file size (from Content-Range/Length)
    private var mirrorIndex = 0
    private var retriesLeft = 3
    private var lastReportedProgress: Double = -1

    // Live Activity (Lock Screen / Dynamic Island).
    private var activity: Activity<ModelDownloadAttributes>?
    private var lastActivityProgress: Double = -1

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        // Wi-Fi only: a 4.4 GB transfer must never silently burn a trainee's
        // cellular data plan (it auto-starts at launch). waitsForConnectivity
        // then parks until Wi-Fi is available instead of failing.
        config.allowsCellularAccess = false
        config.timeoutIntervalForResource = 60 * 60 * 6   // one attempt may span hours
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    var localURL: URL { docs.appendingPathComponent(fileName) }
    private var partialURL: URL { docs.appendingPathComponent(fileName + ".partial") }

    var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    private var partialSize: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: partialURL.path)[.size] as? Int64) ?? 0
    }

    /// Free space available for important downloads, compared to `bytes`.
    /// Unknown capacity → don't block (returns true).
    private static func hasEnoughFreeSpace(bytes: Int64) -> Bool {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let values = try? docs.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return true }
        return available >= bytes
    }

    /// Stream-hash the finished file and compare to the pinned SHA-256. Returns
    /// true (skips) when no hash is pinned — with a loud log so it's not silent.
    private func sha256Matches(_ url: URL) -> Bool {
        guard let expected = Self.expectedSHA256 else {
            print("[ModelDownloader] WARNING: model SHA-256 not pinned — integrity NOT verified.")
            return true
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 8 * 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest.caseInsensitiveCompare(expected) == .orderedSame
    }

    // MARK: - Lifecycle

    /// Called at launch and whenever the app becomes active: if the model isn't
    /// here and the user didn't explicitly delete it, (re)start the download —
    /// resuming from the partial file's exact byte count.
    func resume() {
        if isDownloaded {
            DispatchQueue.main.async {
                self.progress = 1
                self.endActivity(finished: true)
            }
            return
        }
        guard !UserDefaults.standard.bool(forKey: Self.userDeletedKey) else { return }
        if isDownloading {
            // Back from suspension with a transfer "in flight": the connection
            // may be a zombie (alive, delivering nothing). If no bytes arrived
            // recently, cancel and re-issue from the partial's current byte.
            if Date().timeIntervalSince(lastDataAt) > 5 {
                task?.cancel()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.isDownloading else { return }
                    self.beginAttempt()
                }
            }
            return
        }
        // Don't auto-start until the user has opted in via the first-run
        // disclosure (or by tapping Download in Settings / on the record screen).
        guard UserDefaults.standard.bool(forKey: Self.optedInKey) else { return }
        startDownload()
    }

    /// When data last arrived — drives the zombie-connection nudge above.
    private var lastDataAt = Date.distantPast

    /// Start or resume the download. No-op if already downloaded or in flight.
    func startDownload() {
        guard !isDownloaded else { return }
        // Preflight: fail clearly up front rather than climbing to a byte-mismatch
        // error after silently dropping writes on a full disk. ~4.4 GB + headroom.
        guard Self.hasEnoughFreeSpace(bytes: 5_000_000_000) else {
            DispatchQueue.main.async {
                self.isDownloading = false
                self.errorMessage = "Not enough free space — the model needs about 4.4 GB. Free up some space and try again."
            }
            return
        }
        UserDefaults.standard.set(false, forKey: Self.userDeletedKey)
        UserDefaults.standard.set(true, forKey: Self.optedInKey)   // starting = opted in
        DispatchQueue.main.async {
            guard !self.isDownloading else { return }
            self.isDownloading = true
            self.errorMessage = nil
            self.mirrorIndex = 0
            self.retriesLeft = 3
            self.startActivity()
            self.beginAttempt()
        }
    }

    /// Remove the model (Settings → Delete). Remembered so the next launch
    /// doesn't immediately download it again.
    func delete() {
        UserDefaults.standard.set(true, forKey: Self.userDeletedKey)
        task?.cancel()
        try? FileManager.default.removeItem(at: localURL)
        try? FileManager.default.removeItem(at: partialURL)
        DispatchQueue.main.async {
            self.isDownloading = false
            self.progress = 0
            self.endActivity(finished: false)
            ModelManager.shared.modelChanged()
        }
    }

    /// For the LLM engine: return the model if present. Never blocks to download —
    /// the download runs via Settings / auto-resume.
    func ensureModel(onProgress: @escaping (Double) -> Void = { _ in }) async throws -> URL {
        guard isDownloaded else {
            throw NSError(domain: "ModelDownloader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The AI model isn't downloaded yet. Download it in Settings."])
        }
        return localURL
    }

    // MARK: - Transfer

    /// Issue one HTTP attempt against the current mirror, resuming at the
    /// partial file's current size via a Range header.
    private func beginAttempt() {
        let offset = partialSize
        baseOffset = offset
        received = 0
        lastDataAt = Date()   // fresh attempt — give it time before any nudge
        totalBytes = Int64(UserDefaults.standard.double(forKey: Self.expectedTotalKey))
        if totalBytes > 0 {
            let initial = Double(offset) / Double(totalBytes)
            DispatchQueue.main.async { self.progress = initial }
        }

        var request = URLRequest(url: mirrors[mirrorIndex])
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let t = session.dataTask(with: request)
        task = t
        t.resume()
    }

    /// A failed attempt: retry the same mirror a few times, then advance to the
    /// next mirror. The partial file survives throughout, so every retry resumes.
    private func attemptFailed(_ message: String) {
        fileHandle = nil
        if retriesLeft > 0 {
            retriesLeft -= 1
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.isDownloading == true else { return }
                self.beginAttempt()
            }
            return
        }
        if mirrorIndex + 1 < mirrors.count {
            mirrorIndex += 1
            retriesLeft = 3
            // Resume from the partial on the next mirror — the file is byte-
            // identical across mirrors, so this preserves progress (deleting it
            // here made a transient R2 stall during backgrounding restart the
            // whole download from 0). The pinned SHA-256 check at completion is
            // the backstop against the rare case a mirror serves a different file.
            beginAttempt()
            return
        }
        DispatchQueue.main.async {
            self.isDownloading = false
            self.errorMessage = message
            self.endActivity(finished: false)
        }
    }

    private func completeDownload() {
        try? fileHandle?.close()
        fileHandle = nil
        let size = partialSize
        // Only accept a byte-complete file; anything short is a broken stream.
        guard totalBytes > 0, size == totalBytes else {
            attemptFailed("Download ended early (\(size)/\(totalBytes) bytes). Tap Download to continue.")
            return
        }
        // Integrity gate (supply-chain): reject a corrupt/tampered/spliced blob
        // before it ever reaches llama.cpp. No-op (with a warning) until the hash
        // is pinned — see expectedSHA256.
        guard sha256Matches(partialURL) else {
            try? FileManager.default.removeItem(at: partialURL)
            attemptFailed("The downloaded model failed its integrity check — restarting.")
            return
        }
        try? FileManager.default.removeItem(at: localURL)
        do {
            try FileManager.default.moveItem(at: partialURL, to: localURL)
            localURL.excludeFromBackup()   // re-downloadable — keep it out of iCloud backup
        } catch {
            DispatchQueue.main.async {
                self.isDownloading = false
                self.errorMessage = "Couldn't save the downloaded model."
                self.endActivity(finished: false)
            }
            return
        }
        DispatchQueue.main.async {
            self.isDownloading = false
            self.progress = 1
            self.errorMessage = nil
            self.endActivity(finished: true)
            ModelManager.shared.modelChanged()
        }
    }

    // MARK: - Live Activity

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
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

extension ModelDownloader: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); return
        }
        switch http.statusCode {
        case 206:
            // Partial content — parse the full size out of "bytes N-M/TOTAL".
            if let range = http.value(forHTTPHeaderField: "Content-Range"),
               let totalPart = range.split(separator: "/").last, let total = Int64(totalPart) {
                totalBytes = total
            }
        case 200:
            // Server ignored (or we didn't send) the Range — full body follows.
            // Any partial data is superseded; start the file over.
            totalBytes = http.expectedContentLength > 0 ? http.expectedContentLength : 0
            try? FileManager.default.removeItem(at: partialURL)
            baseOffset = 0
        case 416:
            // Range Not Satisfiable: our resume offset is past EOF — the partial
            // is corrupt/oversized. Discard it and restart from zero instead of
            // re-requesting the same bad range forever (the old dead-loop).
            completionHandler(.cancel)
            try? FileManager.default.removeItem(at: partialURL)
            baseOffset = 0
            UserDefaults.standard.removeObject(forKey: Self.expectedTotalKey)
            attemptFailed("Resuming from a bad point — restarting the download.")
            return
        default:
            completionHandler(.cancel)
            attemptFailed("The model server said \(http.statusCode). Tap Download to retry.")
            return
        }
        if totalBytes > 0 {
            UserDefaults.standard.set(Double(totalBytes), forKey: Self.expectedTotalKey)
        }
        if !FileManager.default.fileExists(atPath: partialURL.path) {
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        }
        partialURL.excludeFromBackup()   // in-progress model bytes — off iCloud backup
        fileHandle = try? FileHandle(forWritingTo: partialURL)
        _ = try? fileHandle?.seekToEnd()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Ignore a stale/zombie task's buffered data: writing it through the new
        // attempt's handle could push partialSize past totalBytes (which then
        // 416-looped forever). Matches the identity check in didCompleteWithError.
        guard dataTask === self.task else { return }
        guard let fileHandle else { return }
        try? fileHandle.write(contentsOf: data)
        received += Int64(data.count)
        lastDataAt = Date()
        guard totalBytes > 0 else { return }
        let fraction = Double(baseOffset + received) / Double(totalBytes)
        // Throttle UI updates to ~every half percent.
        if fraction - lastReportedProgress >= 0.005 || fraction >= 1 {
            lastReportedProgress = fraction
            DispatchQueue.main.async {
                self.progress = fraction
                self.errorMessage = nil          // bytes flowing — clear stale errors
                self.updateActivity(fraction)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard self.task === task else { return }   // stale callback from a replaced attempt
        self.task = nil
        if let error {
            try? fileHandle?.close()
            fileHandle = nil
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled { return }   // delete()/nudge handles next step
            attemptFailed("Download interrupted — it'll resume from where it stopped. (\(nsError.localizedDescription))")
        } else {
            completeDownload()
        }
    }
}
