import SwiftUI

/// Settings — manage the on-device models (download the LLM up front; see status
/// of and delete any managed model) and pick the transcription engine.
struct SettingsView: View {
    @State private var downloading = false
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @State private var confirmDelete: ManagedModel?
    @AppStorage("transcriptionEngine") private var engine = TranscriptionEngine.apple.rawValue
    @AppStorage("showMemoryHUD") private var showMemoryHUD = false
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @ObservedObject private var models = ModelManager.shared

    /// Apple's engine only appears on iOS 26+; below that, Whisper only.
    private var engineChoices: [TranscriptionEngine] {
        if #available(iOS 26.0, *) { return TranscriptionEngine.allCases }
        return [.whisper]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ManagedModel.allCases) { modelRow($0) }
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("On-device Models")
                } footer: {
                    Text("Everything runs on your device, offline. The AI model downloads once; the speech models download automatically the first time you record. Delete any to free space — the AI model is required to record.")
                }

                Section {
                    Picker("Speech engine", selection: $engine) {
                        ForEach(engineChoices) { choice in
                            Text(choice.title).tag(choice.rawValue)
                        }
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    Text((TranscriptionEngine(rawValue: engine) ?? .whisper).subtitle)
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
                if downloading {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress)
                        Text("Downloading… \(Int(progress * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Download (~4.3 GB, one time)") { downloadLLM() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            } else if !installed, model.downloadsOnFirstUse {
                Text("Downloads automatically on first recording.")
                    .font(.caption).foregroundStyle(.secondary)
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

    private func downloadLLM() {
        downloading = true
        errorMessage = nil
        Task {
            do {
                _ = try await ModelDownloader.shared.ensureModel { fraction in
                    progress = fraction
                }
                models.objectWillChange.send()   // refresh installed state
            } catch {
                errorMessage = error.localizedDescription
            }
            downloading = false
        }
    }
}
