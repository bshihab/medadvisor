import Foundation
import ActivityKit

/// Downloads the Qwen2.5-7B-Instruct GGUF (~4.3 GB) once into Documents, then
/// runs fully offline. Uses a BACKGROUND URLSession so the download survives the
/// user leaving the app, locking the phone, or even killing the app — the system
/// keeps downloading and relaunches us to save the file. (Chosen over MedGemma
/// 4B after benchmarking — see tools/llm-benchmark/README.md.)
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

    /// Resume data captured when a download is cancelled (e.g. the app was
    /// force-quit) so the next Download continues from where it stopped.
    private var resumeData: Data?

    private lazy var session: URLSession = {
        // Foreground (default) session. Background sessions are heavily throttled
        // by iOS (~10x slower for a big file) and their Live Activity updates lag,
        // so for a one-time 4.3GB download we prioritize SPEED: fast while the app
        // is open; it pauses if you leave and resumes (from resume data) on return.
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    var localURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(fileName)
    }

    var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    /// Re-attach to any in-flight background download (call at launch). Creating
    /// the session also lets the system deliver events from a download that
    /// finished while we were suspended/killed.
    func resume() {
        session.getAllTasks { tasks in
            let active = tasks.contains { $0.state == .running || $0.state == .suspended }
            if active { DispatchQueue.main.async { self.isDownloading = true } }
        }
    }

    /// Start the download (from Settings). No-op if it's already done or running.
    func startDownload() {
        guard !isDownloaded else { return }
        session.getAllTasks { tasks in
            let active = tasks.contains { $0.state == .running || $0.state == .suspended }
            DispatchQueue.main.async {
                self.isDownloading = true
                if active { return }             // already running — just reflect it
                self.errorMessage = nil
                self.progress = 0
                // Resume from where a cancelled download left off, if we can.
                if let data = self.resumeData {
                    self.resumeData = nil
                    self.session.downloadTask(withResumeData: data).resume()
                } else {
                    self.session.downloadTask(with: self.remoteURL).resume()
                }
                self.startActivity()
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
            self.isDownloading = false
            if moved {
                self.progress = 1
                self.endActivity(finished: true)
                Task { @MainActor in ModelManager.shared.modelChanged() }  // refresh badge/state
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
            self.isDownloading = false
            self.endActivity(finished: false)
            if nsError.code == NSURLErrorCancelled {
                // Force-quitting the app cancels the background transfer (iOS
                // behavior). Keep the resume data so Download continues later.
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
