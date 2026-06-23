import SwiftUI

/// App root: a tab bar. Record is the hero; Goals, History, Insights are tabs.
struct RootView: View {
    var body: some View {
        TabView {
            RecordTab()
                .tabItem { Label("Record", systemImage: "mic.fill") }

            NavigationStack { LocationSelectionView(mode: .goalSetting) }
                .tabItem { Label("Goals", systemImage: "target") }

            NavigationStack { HistoryView() }
                .tabItem { Label("History", systemImage: "clock") }

            NavigationStack { InsightsView() }
                .tabItem { Label("Insights", systemImage: "lightbulb") }
        }
    }
}

/// Record tab: one big microphone. Tapping it picks a location, then records.
struct RecordTab: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                NavigationLink {
                    LocationSelectionView(mode: .recording)
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 210, height: 210)
                            .shadow(color: .accentColor.opacity(0.35), radius: 18, y: 6)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 92))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)

                Text("Tap to record a consultation")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                NavigationLink {
                    LLMSpikeView()
                } label: {
                    Text("Developer: on-device LLM test")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .navigationTitle("MedAdvisor")
        }
    }
}
