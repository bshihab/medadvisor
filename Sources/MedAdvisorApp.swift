import SwiftUI

@main
struct MedAdvisorApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                RecordingView()
                    .tabItem { Label("Record", systemImage: "mic") }
                LLMSpikeView()
                    .tabItem { Label("LLM Spike", systemImage: "brain") }
            }
        }
    }
}
