import Foundation
import UIKit
import ActivityKit

/// Downloads the Qwen2.5-7B-Instruct GGUF (~4.3 GB) once into Documents, then
/// runs fully offline. (Chosen over MedGemma 4B after benchmarking — see
/// tools/llm-benchmark/README.md.)
///
/// HYBRID transfer: we keep TWO URLSessions and hand the in-flight download off
/// between them on every foreground/background transition —
///   • App on-screen  → FOREGROUND (default) session: full speed, Live Activity
///     stays in sync.
///   • App backgrounded/closed → BACKGROUND session: iOS-throttled (slower) but
///     it keeps going and survives even a force-quit, and the system relaunches
///     us to save the finished file.
/// The handoff cancels the current task *producing resume data* and restarts it
/// on the other session from where it left off (HuggingFace supports range
/// requests, so no bytes are re-downloaded).
final class ModelDownloader: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = ModelDownloader()
    private override init() { super.init() }

    private let remoteURL = URL(string: "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf")!
    private let fileName = "Qwen2.5-7B-Instruct-Q4_K_M.gguf"
    private static let sessionID = "app.medadvisor.modeldownload"

    /// Live download state (observed by Settings).
    @Published private(set) var progress: Double = 0
    @Published private(set) var isDownloading = false
    @Published private(set) var errorMessage: String?

    /// Stored by the app delegate for background-launch events; called when the
    /// background session finishes delivering events.
    var backgroundCompletion: (() -> Void)?

    // Live Activity (Lock Screen / Dynamic Island) for the download.
    private var activity: Activity<ModelDownloadAttributes>?
    private var lastActivityProgress: Double = -1

    /// Resume data captured when a download is cancelled by the user (e.g. they
    /// tapped Delete or an error killed it) so the next Download continues.
    private var resumeData: Data?

    /// Which way an in-flight session→session handoff is going, if any. While a
    /// handoff is in progress we ignore the cancellation it produces (the restart
    /// is handled by the handoff itself, not the "download stopped" path).
    private enum Handoff { case none, toBackground, toForeground }
    private var handoff: Handoff = .none

    /// Fast, full-speed transfer used while the app is on-screen.
    private lazy var foregroundSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Survives backgrounding/lock/force-quit; iOS-throttled. Recreating it with
    /// the same identifier reconnects to an in-flight transfer after relaunch.
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true   // relaunch the app when done
        config.isDiscretionary = false           // start now, don't defer
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    var localURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(fileName)
    }

    var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    // MARK: - Launch / lifecycle

    /// Re-attach to any in-flight background download (call at launch). Creating
    /// the background session lets iOS deliver events from a transfer that ran
    /// (or finished) while we were suspended/killed; we also re-grab the Live
    /// Activity so we can keep updating it.
    func resume() {
        if let existing = Activity<ModelDownloadAttributes>.activities.first {
            activity = existing
        }
        backgroundSession.getAllTasks { tasks in
            let active = tasks.contains { $0.state == .running || $0.state == .suspended }
            if active { DispatchQueue.main.async { self.isDownloading = true } }
        }
    }

    /// App became active — pull any background transfer up to the fast session.
    func enterForeground() {
        handoffTask(from: backgroundSession, to: foregroundSession, direction: .toForeground)
    }

    /// App is backgrounding — push any foreground transfer down to the session
    /// that survives, so it keeps going while we're away.
    func enterBackground() {
        handoffTask(from: foregroundSession, to: backgroundSession, direction: .toBackground)
    }

    /// Cancel the in-flight download on `source` producing resume data, then
    /// restart it on `dest` from where it left off. A UIKit background-task
    /// assertion buys us the moment needed to complete the swap while the app is
    /// suspending.
    private func handoffTask(from source: URLSession, to dest: URLSession, direction: Handoff) {
        source.getTasksWithCompletionHandler { _, _, downloads in
            guard let task = downloads.first(where: { $0.state == .running || $0.state == .suspended })
            else { return }
            DispatchQueue.main.async {
                self.handoff = direction
                let assertion = UIApplication.shared.beginBackgroundTask(withName: "model-download-handoff")
                task.cancel(byProducingResumeData: { data in
                    DispatchQueue.main.async {
                        self.restart(on: dest, resume: data)
                        self.handoff = .none
                        if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
                    }
                })
            }
        }
    }

    private func restart(on session: URLSession, resume data: Data?) {
        let task = data.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: remoteURL)
        task.resume()
        isDownloading = true
        errorMessage = nil
        resumeData = nil
    }

    // MARK: - Start (from Settings)

    /// Start the download. The app is on-screen when the user taps Download, so we
    /// begin on the fast foreground session; the scene handoff moves it to the
    /// background session if they leave. No-op if it's already done or running.
    func startDownload() {
        guard !isDownloaded else { return }
        activeDownloadExists { running in
            DispatchQueue.main.async {
                self.isDownloading = true
                if running { return }            // already going — just reflect it
                self.errorMessage = nil
                self.progress = 0
                self.restart(on: self.foregroundSession, resume: self.resumeData)
                self.startActivity()
            }
        }
    }

    /// Is a download currently running/suspended on *either* session?
    private func activeDownloadExists(_ completion: @escaping (Bool) -> Void) {
        foregroundSession.getAllTasks { fg in
            let fgActive = fg.contains { $0.state == .running || $0.state == .suspended }
            if fgActive { return completion(true) }
            self.backgroundSession.getAllTasks { bg in
                completion(bg.contains { $0.state == .running || $0.state == .suspended })
            }
        }
    }

    /// For the LLM engine: return the model if present. Never downloads here —
    /// downloading is a deliberate Settings action.
    func ensureModel(onProgress: @escaping (Double) -> Void = { _ in }) async throws -> URL {
        guard isDownloaded else {
            throw NSError(domain: "ModelDownloader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The AI model isn't downloaded yet. Download it in Settings."])
        }
        return localURL
    }

    // MARK: - Live Activity

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        let state = ModelDownloadAttributes.ContentState(progress: 0, finished: false)
        let content = ActivityContent(state: state, staleDate: nil)
        activity = try? Activity.request(attributes: ModelDownloadAttributes(), content: content)
        lastActivityProgress = 0
    }

    private func updateActivity(_ p: Double) {
        // Throttle — ActivityKit rate-limits updates, so only push every ~2%.
        guard let activity, p - lastActivityProgress >= 0.02 else { return }
        lastActivityProgress = p
        let state = ModelDownloadAttributes.ContentState(progress: p, finished: false)
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func endActivity(finished: Bool) {
        guard let activity else { return }
        self.activity = nil
        let state = ModelDownloadAttributes.ContentState(
            progress: finished ? 1 : lastActivityProgress, finished: finished)
        let content = ActivityContent(state: state, staleDate: nil)
        Task {
            await activity.update(content)
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(4)))
        }
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.progress = fraction
            self.isDownloading = true
            self.errorMessage = nil          // bytes flowing → clear any stale "stopped" note
            self.updateActivity(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Move the temp file synchronously — it's deleted when this returns.
        let dest = localURL
        try? FileManager.default.removeItem(at: dest)
        let moved = (try? FileManager.default.moveItem(at: location, to: dest)) != nil
        DispatchQueue.main.async {
            self.handoff = .none
            self.isDownloading = false
            if moved {
                self.progress = 1
                self.endActivity(finished: true)
                Task { @MainActor in ModelManager.shared.modelChanged() }  // refresh state
            } else {
                self.errorMessage = "Couldn't save the downloaded model."
                self.endActivity(finished: false)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        DispatchQueue.main.async {
            // Mid-handoff cancellation — the restart is handled by handoffTask, so
            // don't treat it as the user stopping the download.
            if self.handoff != .none { return }

            self.isDownloading = false
            self.endActivity(finished: false)
            if nsError.code == NSURLErrorCancelled {
                self.resumeData = resume
                self.errorMessage = (resume != nil)
                    ? "Download stopped. Tap Download to resume where it left off."
                    : nil
            } else {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Background events finished being delivered — let the system know we're done.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}
