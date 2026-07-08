import SwiftUI

@main
struct MedAdvisorApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    ModelDownloader.shared.resume()
                    RubricSync.refresh()   // cloud rubrics (silent, offline-safe)
                }
        }
        // Re-drive the download whenever the app comes back — transfers only run
        // at full speed while we're active, and resume() picks up from the exact
        // byte the partial file left off at.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { ModelDownloader.shared.resume() }
        }
    }
}
