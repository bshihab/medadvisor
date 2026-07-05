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
///   • App backgrounded/locked → BACKGROUND session: iOS-throttled (slower) but
///     it keeps going and the system relaunches us to save the finished file.
/// A force-quit cancels the transfer; we persist its resume data to DISK so the
/// next launch continues from where it stopped instead of restarting from 0.
/// The handoff cancels the current task *producing resume data* and restarts it
/// on the other session (HuggingFace supports range requests, so no bytes are
/// re-downloaded).
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

    /// The download task we currently consider "ours". Used to tell a stale
    /// cancellation (e.g. a force-quit event redelivered after we've already
    /// relaunched the download) apart from a real stop, and to hand the transfer
    /// between sessions without racing on getTasks().
    private var currentTask: URLSessionDownloadTask?

    /// Whether `currentTask` is running on the (throttled) background session.
    /// Drives the foreground/background handoff so we only move it when needed.
    private var currentIsBackground = false

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

    /// Survives backgrounding/lock; iOS-throttled. Recreating it with the same
    /// identifier reconnects to an in-flight transfer after relaunch.
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

    /// Resume data persisted to disk, so a force-quit (which wipes memory) still
    /// lets us continue from where the transfer stopped.
    private var resumeDataURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(fileName + ".resume")
    }

    var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    private func saveResumeData(_ data: Data?) {
        if let data { try? data.write(to: resumeDataURL, options: .atomic) }
        else { try? FileManager.default.removeItem(at: resumeDataURL) }
    }
    private func loadResumeData() -> Data? { try? Data(contentsOf: resumeDataURL) }

    // MARK: - Launch / lifecycle

    /// Re-attach to any in-flight download and de-dupe Live Activities (call at
    /// launch). If nothing is running but we have saved resume data, continue
    /// from where a force-quit left off instead of starting over.
    func resume() {
        reconcileActivities()
        // If a transfer is still live on the background session (system relaunch
        // or a reopen), adopt its task by reference so we can hand it off cleanly.
        backgroundSession.getAllTasks { tasks in
            let live = tasks.first(where: { $0.state == .running || $0.state == .suspended }) as? URLSessionDownloadTask
            DispatchQueue.main.async {
                if let live {
                    self.currentTask = live
                    self.currentIsBackground = true
                    self.isDownloading = true
                    self.enterForeground()             // app is active → pull it to the fast session
                    return
                }
                if !self.isDownloaded, let data = self.loadResumeData() {
                    // Auto-continue from the saved byte offset.
                    self.isDownloading = true
                    self.restart(on: self.foregroundSession, background: false, resume: data)
                    self.startActivity()
                } else if self.isDownloaded {
                    self.endActivity(finished: true)   // clear any leftover activity
                }
            }
        }
    }

    /// App became active — pull a background transfer up to the fast session.
    func enterForeground() {
        guard isDownloading, currentIsBackground, let task = currentTask else { return }
        performHandoff(task, to: foregroundSession, background: false, direction: .toForeground)
    }

    /// App is backgrounding — push a foreground transfer down to the durable
    /// session so it keeps going while we're away.
    func enterBackground() {
        guard isDownloading, !currentIsBackground, let task = currentTask else { return }
        performHandoff(task, to: backgroundSession, background: true, direction: .toBackground)
    }

    /// Cancel the in-flight task producing resume data, then restart it on `dest`
    /// from where it left off. A UIKit background-task assertion buys us the
    /// moment needed to complete the swap while the app is suspending.
    private func performHandoff(_ task: URLSessionDownloadTask, to dest: URLSession,
                                background: Bool, direction: Handoff) {
        handoff = direction
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "model-download-handoff")
        task.cancel(byProducingResumeData: { data in
            DispatchQueue.main.async {
                self.restart(on: dest, background: background, resume: data)
                self.handoff = .none
                if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
            }
        })
    }

    private func restart(on session: URLSession, background: Bool, resume data: Data?) {
        let task = data.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: remoteURL)
        currentTask = task
        currentIsBackground = background
        task.resume()
        isDownloading = true
        errorMessage = nil
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
                let resume = self.loadResumeData()
                if resume == nil { self.progress = 0 }   // only reset when starting fresh
                self.restart(on: self.foregroundSession, background: false, resume: resume)
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

    /// Reattach to a surviving activity (e.g. after force-quit) and end any
    /// duplicates, so we never show more than one.
    private func reconcileActivities() {
        let all = Activity<ModelDownloadAttributes>.activities
        guard let first = all.first else { return }
        activity = first
        lastActivityProgress = -1            // force the next update through
        for extra in all.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        reconcileActivities()
        guard activity == nil else { return }   // reused an existing one — don't add a second
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

    /// End the download's Live Activity — and any stray duplicates — showing a
    /// final state.
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

extension ModelDownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.progress = fraction
            self.isDownloading = true
            self.errorMessage = nil             // bytes flowing → clear any stale "stopped" note
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
            self.currentTask = nil
            self.isDownloading = false
            self.saveResumeData(nil)            // done — clear saved resume data
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
            // Mid-handoff cancellation — the restart is handled by handoffTask.
            if self.handoff != .none { return }

            // A cancellation from a task that isn't our current one is a stale
            // redelivery (e.g. the force-quit event arriving after we already
            // relaunched). Keep its resume data as a fallback, but don't stop.
            if let current = self.currentTask, task !== current {
                if let resume, self.loadResumeData() == nil { self.saveResumeData(resume) }
                return
            }

            self.currentTask = nil
            self.isDownloading = false
            if nsError.code == NSURLErrorCancelled, let resume {
                // Paused (e.g. force-quit) but recoverable. Persist resume data so
                // the next launch continues, and KEEP the Live Activity — the
                // download isn't finished, and reattaching to the same one on
                // relaunch avoids a stuck-old + new duplicate.
                self.saveResumeData(resume)
                self.errorMessage = "Download paused. It'll continue when you reopen, or tap Download."
            } else {
                // Unrecoverable (cancel with no resume data, or a real error).
                self.endActivity(finished: false)
                self.errorMessage = (nsError.code == NSURLErrorCancelled) ? nil : error.localizedDescription
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
