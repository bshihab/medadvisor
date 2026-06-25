import SwiftUI

/// Recording mode: record an encounter, then run the full on-device pipeline
/// (transcribe → diarize → score) and show feedback.
struct RecordingView: View {
    let location: AppLocation

    @StateObject private var recorder = AudioRecorder()
    @StateObject private var processor = EncounterProcessor()
    @State private var showFeedback = false
    @State private var showCheckmark = false
    @State private var consentConfirmed = false
    @State private var showConsentDialog = false

    private var rubric: Rubric? { RubricLoader.load(for: location) }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            LevelMeter(level: recorder.level)
                .frame(height: 12)
                .padding(.horizontal, 40)

            Text(timeString(recorder.elapsed))
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(.secondary)

            recordButton

            liveFeed

            processSection

            Spacer()
        }
        .padding()
        .navigationTitle(location.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            recorder.requestPermission()
            processor.requestPermissions()
        }
        .sheet(isPresented: $showFeedback) {
            if case .done(let feedback) = processor.stage, let rubric {
                FeedbackView(feedback: feedback, rubric: rubric,
                             transcript: processor.redactedTranscript,
                             turns: processor.transcriptTurns.isEmpty ? nil : processor.transcriptTurns)
            }
        }
        .alert("Microphone access needed", isPresented: $recorder.permissionDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable microphone access in Settings to record consultations.")
        }
        .confirmationDialog("Patient consent",
                            isPresented: $showConsentDialog,
                            titleVisibility: .visible) {
            Button("The patient has consented to recording") {
                consentConfirmed = true
                startRecording()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Confirm the patient has given consent to be recorded before you begin. Audio is processed on-device and deleted after analysis.")
        }
        .overlay {
            if showCheckmark {
                CheckmarkOverlay().transition(.opacity)
            }
        }
    }

    // MARK: - Live feed

    @ViewBuilder
    private var liveFeed: some View {
        if recorder.isRecording {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        if recorder.liveUtterances.isEmpty && recorder.livePartial.isEmpty {
                            Text("Listening…")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        }
                        ForEach(Array(recorder.liveUtterances.enumerated()), id: \.offset) { _, phrase in
                            liveBubble(phrase, forming: false)
                        }
                        if !recorder.livePartial.isEmpty {
                            liveBubble(recorder.livePartial, forming: true)
                        }
                        Color.clear.frame(height: 1).id("liveBottom")
                    }
                    .padding(12)
                }
                .frame(maxHeight: 300)
                .onChange(of: recorder.livePartial) { _, _ in scrollLive(proxy) }
                .onChange(of: recorder.liveUtterances.count) { _, _ in scrollLive(proxy) }
            }
            .padding(.horizontal)
        }
    }

    private func scrollLive(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("liveBottom", anchor: .bottom)
        }
    }

    private func liveBubble(_ text: String, forming: Bool) -> some View {
        HStack {
            Text(text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(forming ? 0.12 : 0.2),
                           in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(.primary)
            Spacer(minLength: 40)
        }
        .opacity(forming ? 0.65 : 1)
    }

    // MARK: - Process section

    @ViewBuilder
    private var processSection: some View {
        if let latest = recorder.recordings.first, !recorder.isRecording {
            VStack(spacing: 12) {
                stageView(url: latest)
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func stageView(url: URL) -> some View {
        switch processor.stage {
        case .idle:
            Button("Transcribe & analyze") { runProcessing(url: url) }
                .buttonStyle(.borderedProminent)
                .disabled(rubric == nil)
            if rubric == nil {
                Text("Rubric not bundled — check project resources.")
                    .font(.caption).foregroundStyle(.red)
            }
        case .transcribing:
            ProgressView("Transcribing on-device…")
        case .identifyingSpeakers:
            ProgressView("Identifying speakers…")
        case .redacting:
            ProgressView("Removing identifiers…")
        case .preparingModel(let fraction):
            VStack(spacing: 8) {
                ProgressView(value: fraction)
                Text(fraction < 0.001 ? "Preparing AI model…"
                                      : "Downloading AI model (one time)… \(Int(fraction * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .scoring(let done, let total):
            VStack(spacing: 8) {
                ProgressView(value: Double(done), total: Double(total))
                    .progressViewStyle(.linear)
                    .animation(.easeInOut, value: done)
                Text("Analyzing \(done + 1) of \(total)…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .summarizing:
            ProgressView("Writing summary…")
        case .done:
            Button("View feedback") { showFeedback = true }
                .buttonStyle(.borderedProminent)
        case .error(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    private func runProcessing(url: URL) {
        guard let rubric else { return }
        Task {
            await processor.process(liveTranscript: recorder.liveText, url: url, rubric: rubric)
            if case .done(let feedback) = processor.stage {
                let record = ConsultationRecord(
                    id: UUID().uuidString,
                    date: Date(),
                    locationRaw: location.rawValue,
                    transcript: processor.redactedTranscript,
                    turns: processor.transcriptTurns.isEmpty ? nil : processor.transcriptTurns,
                    feedback: feedback)
                FeedbackStore.shared.add(record)
                recorder.deleteRecording(url)   // privacy: drop raw audio after analysis
                withAnimation { showCheckmark = true }
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                withAnimation { showCheckmark = false }
                showFeedback = true
            }
        }
    }

    // MARK: - Recording controls

    private var recordButton: some View {
        Button(action: toggleRecording) {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 96, height: 96)
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.toggle()   // stop
            return
        }
        guard consentConfirmed else {
            showConsentDialog = true
            return
        }
        startRecording()
    }

    private func startRecording() {
        processor.reset()
        recorder.toggle()
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Simple animated amplitude bar.
private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(Color.green)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
    }
}

#Preview {
    RecordingView(location: .outpatientClinic)
}
