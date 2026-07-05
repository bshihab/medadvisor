import Foundation

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

    private lazy var session: URLSession = {
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
                self.session.downloadTask(with: self.remoteURL).resume()
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
                Task { @MainActor in ModelManager.shared.modelChanged() }  // refresh badge/state
            } else {
                self.errorMessage = "Couldn't save the downloaded model."
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }
        DispatchQueue.main.async {
            self.isDownloading = false
            self.errorMessage = error.localizedDescription
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
