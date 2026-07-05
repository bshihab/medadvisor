import ActivityKit

/// Live Activity model for the model download. Shared by the app (which starts
/// and updates the activity) and the widget extension (which renders it).
struct ModelDownloadAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 0...1 download progress.
        var progress: Double
        /// True once the model has finished downloading.
        var finished: Bool
    }
}
