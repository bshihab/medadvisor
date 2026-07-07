import SwiftUI

@main
struct MedAdvisorApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    // Sync model state at launch (the OS may have finished the
                    // asset-pack download while we weren't running) and clean up
                    // any leftover download Live Activity.
                    ModelDownloader.shared.resume()
                }
        }
    }
}
