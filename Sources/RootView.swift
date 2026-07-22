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
    @AppStorage("modelDownloadSeen") private var modelDownloadSeen = false
    @ObservedObject private var account = AccountStore.shared
    @State private var showDownloadDisclosure = false

    var body: some View {
        tabs
            .memoryHUD(showMemoryHUD)
            .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme ?? nil)
            .onAppear {
                // First-run disclosure: the ~4.4GB model no longer downloads
                // silently — the user opts in here (or later in Settings).
                if !modelDownloadSeen && !ModelDownloader.shared.isDownloaded {
                    showDownloadDisclosure = true
                }
            }
            .alert("Download the AI model", isPresented: $showDownloadDisclosure) {
                Button("Download now") {
                    modelDownloadSeen = true
                    ModelDownloader.shared.startDownload()
                }
                Button("Later", role: .cancel) { modelDownloadSeen = true }
            } message: {
                Text("MedAdvisor needs a one-time ~4.4 GB AI model to score consultations privately on your device. It downloads over Wi-Fi only and never leaves your phone. You can also start this anytime from Settings.")
            }
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
        // Rebuild the whole TabView when the account/role changes — a
        // conditionally-included tab otherwise leaves a stale blank tab after
        // switching between a mentor and a trainee account on the same device.
        .id("\(account.uid ?? "none")-\(account.org?.role ?? "none")")
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
