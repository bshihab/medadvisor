import SwiftUI

/// Settings — lets the user download the AI model up front (it's cached after
/// the first download and never re-downloaded).
struct SettingsView: View {
    @State private var downloaded = ModelDownloader.shared.isDownloaded
    @State private var downloading = false
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @AppStorage("useParakeet") private var useParakeet = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("MedGemma 4B")
                            .font(.headline)
                        Spacer()
                        Text(downloaded ? "Installed" : "Not downloaded")
                            .foregroundStyle(downloaded ? .green : .secondary)
                    }

                    if downloaded {
                        Text("Ready — the AI runs fully on your device, offline.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if downloading {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: progress)
                            Text("Downloading… \(Int(progress * 100))%")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Download model (~2.5 GB, one time)") { download() }
                            .buttonStyle(.borderedProminent)
                    }

                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("AI Model")
                } footer: {
                    Text("Downloaded once over Wi-Fi, then stored on your device. Recording and feedback work offline after that.")
                }

                Section {
                    Picker("Speech engine", selection: $useParakeet) {
                        Text("Whisper (small.en)").tag(false)
                        Text("Parakeet (NVIDIA)").tag(true)
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    Text(useParakeet
                         ? "Parakeet TDT — usually fewer errors and sharper speaker timing. Downloads ~600 MB once."
                         : "WhisperKit small.en. Switch to Parakeet to compare accuracy on a recording.")
                }

                Section("Privacy") {
                    Label("Audio and transcripts never leave your device.",
                          systemImage: "lock.fill")
                        .font(.subheadline)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func download() {
        downloading = true
        errorMessage = nil
        Task {
            do {
                _ = try await ModelDownloader.shared.ensureModel { fraction in
                    progress = fraction
                }
                downloaded = true
            } catch {
                errorMessage = error.localizedDescription
            }
            downloading = false
        }
    }
}
