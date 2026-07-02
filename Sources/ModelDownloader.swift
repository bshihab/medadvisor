import Foundation

/// Downloads the Qwen2.5-7B-Instruct GGUF model once into the app's Documents
/// folder, then runs fully offline. Chosen over MedGemma 4B after benchmarking:
/// our task is rubric-APPLYING (judgment/instruction-following), where Qwen 7B
/// is far more accurate — MedGemma 4B chronically over-scored. See
/// tools/llm-benchmark/README.md.
final class ModelDownloader: NSObject, @unchecked Sendable {
    static let shared = ModelDownloader()

    private let remoteURL = URL(string: "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf")!
    private let fileName = "Qwen2.5-7B-Instruct-Q4_K_M.gguf"

    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: ((Double) -> Void)?

    var localURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(fileName)
    }

    var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    /// Returns the local model URL, downloading it first if needed.
    func ensureModel(onProgress: @escaping (Double) -> Void) async throws -> URL {
        if isDownloaded { return localURL }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.onProgress = onProgress
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session.downloadTask(with: remoteURL).resume()
        }
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.onProgress?(fraction) }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            let dest = localURL
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
