import SwiftUI

/// Settings — manage the on-device models (download the LLM up front; see status
/// of and delete any managed model) and pick the transcription engine.
struct SettingsView: View {
    @State private var confirmDeleteLLM: LLMModel?
    @State private var switchBlocked = false
    /// Re-read on every `models.revision` bump so rows reflect the live choice.
    @State private var selectedLLM: LLMModel = LLMModel.selected
    @AppStorage("showMemoryHUD") private var showMemoryHUD = false
    @AppStorage("benchmarkEnabled") private var benchmarkEnabled = false
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @ObservedObject private var models = ModelManager.shared
    @ObservedObject private var downloader = ModelDownloader.shared
    @ObservedObject private var benchmark = BenchmarkRecorder.shared
    @State private var savedRuns: [BenchmarkRecorder.SavedRun] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    AccountRow()
                }

                // One models section, not two. The old "On-device Models" section
                // iterated ManagedModel, which holds a single `.llm` case with a
                // HARDCODED "Qwen 2.5-7B" title and a hardcoded "~4.3 GB" download
                // button. Once a second model existed that row showed the wrong
                // name and the wrong size, and the screen listed the 7B twice with
                // two Delete buttons — on a screen where Delete removes 4.3 GB.
                // LLMModel.allCases drives everything now; its footer absorbed the
                // offline/speech-to-text note that used to live here.
                Section {
                    ForEach(LLMModel.allCases) { llmRow($0) }
                    if let error = downloader.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("AI Model")
                } footer: {
                    Text("Everything runs on your device, offline. Speech-to-text uses Apple's built-in on-device engine — no download.\n\nQwen 2.5-7B is the default and is what your feedback has been graded with. A second model is available to try — it is smaller and faster, but its feedback is still being evaluated, so treat anything it says as provisional. Switching never deletes the other model: each is kept separately, and you can switch back at any time.")
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
                } header: {
                    Text("Developer")
                } footer: {
                    Text("“Record benchmark” times every analysis — throughput, per-stage timing, peak memory, thermal state, battery — and saves each run below.")
                }

                // Always visible: an empty hidden section makes "the toggle
                // was off during the run" indistinguishable from "my runs are
                // gone" — which has already cost one irreplaceable result.
                if savedRuns.isEmpty {
                    Section {
                        Text(benchmarkEnabled
                             ? "No runs recorded yet. “Record benchmark” is ON — the next analysis will be captured."
                             : "No runs recorded yet — and “Record benchmark” is OFF, so analyses are NOT being captured. Turn it on above before running one.")
                            .font(.caption).foregroundStyle(.secondary)
                    } header: {
                        Text("Benchmark runs (0)")
                    }
                } else {
                    Section {
                        ForEach(savedRuns) { run in
                            VStack(alignment: .leading, spacing: 6) {
                                // Engine + failure marker on the header line:
                                // with llama/0.6B/4B runs accumulating across
                                // days, a bare timestamp can't identify a row.
                                Text("\(BenchmarkRecorder.displayTime(run.report.recordedAt)) · \(run.report.engine)\(run.report.success ? "" : " · FAILED")")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(BenchmarkRecorder.summaryText(run.report))
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                ShareLink(item: run.url) {
                                    Label("Export JSON", systemImage: "square.and.arrow.up")
                                        .font(.caption)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        Button("Delete all runs", role: .destructive) {
                            benchmark.deleteAllSavedRuns()
                            savedRuns = []
                        }
                    } header: {
                        Text("Benchmark runs (\(savedRuns.count))")
                    } footer: {
                        Text("Newest first. Every analysis saves its own run, so back-to-back sessions are all here — compare tok/s down the list to see thermal throttling.")
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear { savedRuns = benchmark.savedRuns() }
            // A run that finishes while Settings is open lands in the list too.
            .onChange(of: benchmark.lastReportURL) { _, _ in savedRuns = benchmark.savedRuns() }
            .confirmationDialog("Delete this model?",
                                isPresented: Binding(
                                    get: { confirmDeleteLLM != nil },
                                    set: { if !$0 { confirmDeleteLLM = nil } }),
                                titleVisibility: .visible) {
                if let m = confirmDeleteLLM {
                    Button("Delete \(m.title)", role: .destructive) {
                        // If the in-use model is deleted, fall back to the
                        // default so the app is never pointed at a missing file.
                        if m == LLMModel.selected, m != LLMModel.fallback {
                            LLMEngine.shared.selectModel(.fallback)
                            selectedLLM = .fallback
                        }
                        downloader.delete(m)
                        confirmDeleteLLM = nil
                    }
                    Button("Cancel", role: .cancel) { confirmDeleteLLM = nil }
                }
            } message: {
                Text("You can download it again later. The other model on your device is not affected.")
            }
            .alert("Analysis in progress", isPresented: $switchBlocked) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The model can't be changed while a consultation is being analysed. Wait for it to finish, then try again.")
            }
        }
        // Apply the theme to the Settings sheet itself, live — a sheet doesn't
        // pick up the root's preferredColorScheme change while it's already open.
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme ?? nil)
        // Re-key the sheet content when the choice changes: switching to System
        // (nil) doesn't re-resolve an already-presented sheet without it.
        .id("appearance-\(appearance)")
    }

    /// One selectable GGUF. Download, select and delete are all per-model, so
    /// no action here can touch a model the user already has on disk.
    @ViewBuilder
    private func llmRow(_ model: LLMModel) -> some View {
        let installed = downloader.isDownloaded(model)   // depends on models.revision
        let isSelected = selectedLLM == model
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.title).font(.headline)
                        if isSelected {
                            Text("IN USE")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.tint, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    Text(model.blurb).font(.caption).foregroundStyle(.secondary)
                    Text(model.approxSize).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(installed ? "Installed" : "Not installed")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(installed ? .green : .secondary)
            }

            HStack(spacing: 10) {
                if !installed {
                    if isSelected, downloader.isDownloading {
                        ProgressView(value: downloader.progress)
                        Text("\(Int(downloader.progress * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Download (\(model.approxSize))") {
                            // Selecting first points the downloader at this model.
                            if LLMEngine.shared.selectModel(model) {
                                selectedLLM = model
                                downloader.startDownload()
                            } else { switchBlocked = true }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                } else if !isSelected {
                    Button("Use this model") {
                        if LLMEngine.shared.selectModel(model) { selectedLLM = model }
                        else { switchBlocked = true }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }

                if installed {
                    Button(role: .destructive) { confirmDeleteLLM = model } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(isSelected && downloader.isDownloading)
                }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: models.revision) { selectedLLM = LLMModel.selected }
    }

    @ViewBuilder
}
