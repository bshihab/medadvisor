import SwiftUI

/// Settings — manage the on-device models (download the LLM up front; see status
/// of and delete any managed model) and pick the transcription engine.
struct SettingsView: View {
    @State private var confirmDelete: ManagedModel?
    @AppStorage("showMemoryHUD") private var showMemoryHUD = false
    @AppStorage("benchmarkEnabled") private var benchmarkEnabled = false
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @ObservedObject private var models = ModelManager.shared
    @ObservedObject private var downloader = ModelDownloader.shared
    @ObservedObject private var benchmark = BenchmarkRecorder.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    AccountRow()
                }

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
                    Toggle("Record benchmark", isOn: $benchmarkEnabled)
                    if let summary = benchmark.lastSummaryText {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Last run").font(.caption).foregroundStyle(.secondary)
                            Text(summary)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if let url = benchmark.lastReportURL {
                            ShareLink(item: url) {
                                Label("Export benchmark JSON", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Memory overlay diagnoses the model memory ceiling. “Record benchmark” times your next analysis — throughput, per-stage timing, peak memory, thermal state, and battery drain — and lets you export it as JSON for the write-up.")
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
                Text("This removes the ~4.4 GB AI model from your phone. You'll need to download it again before you can analyze recordings.")
            }
        }
        // Apply the theme to the Settings sheet itself, live — a sheet doesn't
        // pick up the root's preferredColorScheme change while it's already open.
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme ?? nil)
        // Re-key the sheet content when the choice changes: switching to System
        // (nil) doesn't re-resolve an already-presented sheet without it.
        .id("appearance-\(appearance)")
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
                        Text("Keep the app open — the screen stays awake, so you can just set the phone down. If you do leave, nothing is lost: it resumes from the exact spot when you come back.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Download (~4.3 GB, one time)") { downloader.startDownload() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Text("~4.4 GB, one time. Fastest with the app open; progress is saved continuously, so nothing is ever lost if you leave.")
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
