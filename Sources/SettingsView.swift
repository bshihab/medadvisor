import SwiftUI

/// Settings — manage the on-device models (download the LLM up front; see status
/// of and delete any managed model) and pick the transcription engine.
struct SettingsView: View {
    @State private var confirmDelete: ManagedModel?
    @AppStorage("showMemoryHUD") private var showMemoryHUD = false
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @ObservedObject private var models = ModelManager.shared
    @ObservedObject private var downloader = ModelDownloader.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ManagedModel.allCases) { modelRow($0) }
                    if let error = downloader.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("On-device Models")
                } footer: {
                    Text("Everything runs on your device, offline. The AI model downloads once (required to record); speech-to-text uses Apple's built-in on-device engine — no download.")
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(Appearance.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Privacy") {
                    Label("Audio and transcripts never leave your device.",
                          systemImage: "lock.fill")
                        .font(.subheadline)
                }

                Section {
                    Toggle("Show memory usage", isOn: $showMemoryHUD)
                } footer: {
                    Text("Live overlay of the app's memory footprint + headroom before iOS kills it — for diagnosing the on-device model memory ceiling.")
                }

                Section("Developer") {
                    NavigationLink {
                        LLMSpikeView()
                    } label: {
                        Label("On-device LLM test", systemImage: "hammer")
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete this model?",
                                isPresented: Binding(
                                    get: { confirmDelete != nil },
                                    set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible) {
                if let model = confirmDelete {
                    Button("Delete \(model.title)", role: .destructive) {
                        models.delete(model)
                        confirmDelete = nil
                    }
                    Button("Cancel", role: .cancel) { confirmDelete = nil }
                }
            } message: {
                Text("It will re-download the next time it's needed.")
            }
        }
        // Apply the theme to the Settings sheet itself, live — a sheet doesn't
        // pick up the root's preferredColorScheme change while it's already open.
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme ?? nil)
    }

    @ViewBuilder
    private func modelRow(_ model: ManagedModel) -> some View {
        let installed = models.isInstalled(model)   // depends on models.revision
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(.headline)
                    Text("\(model.role) · \(model.approxSize)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(installed ? "Installed" : "Not installed")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(installed ? .green : .secondary)
            }

            if model == .llm, !installed {
                if downloader.isDownloading {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: downloader.progress)
                        Text("Downloading… \(Int(downloader.progress * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Keep MedAdvisor open while it downloads. If you leave, it pauses and resumes when you come back.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Download (~4.3 GB, one time)") { downloader.startDownload() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Text("~4.3 GB, one time. Keep MedAdvisor open while it downloads — it's fastest that way. If you leave, it pauses and resumes when you return.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if installed {
                Button(role: .destructive) { confirmDelete = model } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
