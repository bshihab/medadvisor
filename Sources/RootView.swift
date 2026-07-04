import SwiftUI

/// App root: a tab bar. Record is the hero — it opens straight onto the
/// recording screen (no intermediate screen); Goals, History, Insights are tabs.
struct RootView: View {
    @AppStorage("showMemoryHUD") private var showMemoryHUD = false

    var body: some View {
        tabs.memoryHUD(showMemoryHUD)
    }

    private var tabs: some View {
        TabView {
            RecordHome()
                .tabItem { Label("Record", systemImage: "mic.fill") }

            NavigationStack { LocationSelectionView(mode: .goalSetting) }
                .tabItem { Label("Goals", systemImage: "target") }

            NavigationStack { HistoryView() }
                .tabItem { Label("History", systemImage: "clock") }

            NavigationStack { InsightsView() }
                .tabItem { Label("Insights", systemImage: "lightbulb") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// The Record tab: opens directly onto the recording screen for the last-used
/// location. A location chip on the idle screen opens a slide-up card to switch
/// panels — no separate "pick a location" screen to wade through first.
struct RecordHome: View {
    @AppStorage("lastLocation") private var locationRaw = AppLocation.outpatientClinic.rawValue
    @State private var showLocationPicker = false

    private var location: AppLocation { AppLocation(rawValue: locationRaw) ?? .outpatientClinic }

    var body: some View {
        NavigationStack {
            RecordingView(location: location,
                          onTapLocation: { showLocationPicker = true })
                // Rebuild cleanly if the location changes (only possible while
                // idle, since the chip is hidden during recording).
                .id(location)
                .sheet(isPresented: $showLocationPicker) {
                    LocationPickerSheet(selectedRaw: $locationRaw)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
        }
    }
}

/// Slide-up card for choosing the encounter location. Replaces the old
/// full-screen 4-card gate; picking a location dismisses back to recording.
struct LocationPickerSheet: View {
    @Binding var selectedRaw: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(AppLocation.allCases) { location in
                Button {
                    selectedRaw = location.rawValue
                    dismiss()
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(location.rawValue)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(location.blurb)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if location.rawValue == selectedRaw {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Where is this encounter?")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
