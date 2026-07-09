import SwiftUI

/// Light / Dark / System appearance, persisted in UserDefaults ("appearance").
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    /// nil = follow the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// App root: two tabs. Record is the hero — it opens straight onto the recording
/// screen; Progress combines the old History, Insights, and Goals into one hub.
/// Settings is a gear on each screen rather than a tab.
struct RootView: View {
    @AppStorage("showMemoryHUD") private var showMemoryHUD = false
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @ObservedObject private var account = AccountStore.shared

    var body: some View {
        tabs
            .memoryHUD(showMemoryHUD)
            .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme ?? nil)
    }

    private var tabs: some View {
        TabView {
            RecordHome()
                .tabItem { Label("Record", systemImage: "mic.fill") }

            ProgressHome()
                .tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }

            // Mentors get a third tab: their cohort, natively. Role-gated by
            // /v1/me, so trainees never see it.
            if account.org?.role == "admin" {
                MentorHome()
                    .tabItem { Label("Cohort", systemImage: "person.2.fill") }
            }
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
                // Note: no .id(location) here — it forced a full rebuild that made
                // the picker sheet vanish instead of animating away. The rubric is
                // derived from `location` live, and recorder/processor don't depend
                // on it, so a plain value change is enough.
                .settingsGear()
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
