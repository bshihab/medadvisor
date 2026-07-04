import SwiftUI

/// Recording mode: record an encounter (pause/resume supported), then run the
/// full on-device pipeline (transcribe → attribute → score) with the rubric
/// filling in live, and show feedback.
struct RecordingView: View {
    let location: AppLocation

    @StateObject private var recorder = AudioRecorder()
    @StateObject private var processor = EncounterProcessor()
    @ObservedObject private var models = ModelManager.shared
    @State private var showFeedback = false
    @State private var consentConfirmed = false
    @State private var showConsentDialog = false

    private var rubric: Rubric? { RubricLoader.load(for: location) }
    private var llmReady: Bool { models.isInstalled(.llm) }

    private var isProcessing: Bool {
        switch processor.stage {
        case .idle, .done, .error: return false
        default: return true
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            if isProcessing {
                processingSection
            } else {
                Spacer()
                recordingSection
                Spacer()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // fill the screen so
        .background { gradeGradient }                        // the glow spans edge-to-edge
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
        .alert("Patient consent", isPresented: $showConsentDialog) {
            Button("Reject", role: .cancel) {}
            Button("Accept") {
                consentConfirmed = true
                startRecording()
            }
        } message: {
            Text("Confirm the patient has consented to being recorded before you begin. Audio is processed on-device and deleted after analysis.")
        }
    }

    // MARK: - Recording section

    @ViewBuilder
    private var recordingSection: some View {
        Text(timeString(recorder.elapsed))
            .font(.system(size: 56, weight: .light, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(recorder.isRecording ? .primary : .secondary)
            .contentTransition(.numericText())

        if recorder.isRecording {
            WaveformView(levels: recorder.waveform,
                         color: recorder.isPaused ? .secondary : .red)
                .frame(height: 96)
                .padding(.horizontal, 8)

            Label(recorder.isPaused ? "Paused" : "Recording",
                  systemImage: recorder.isPaused ? "pause.circle" : "waveform")
                .font(.subheadline)
                .foregroundStyle(recorder.isPaused ? Color.secondary : Color.red)

            if recorder.liveActive {
                liveTranscript
            }

            recordingControls
        } else if let latest = recorder.recordings.first {
            finishedControls(url: latest)
        } else if !llmReady {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Download the AI model to record")
                .font(.headline)
            Text("Go to Settings and download the AI model (one time). Recording needs it to give feedback.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        } else {
            idleRecordButton
            Text("Tap to record the consultation")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// Soft grading-palette gradient (green → orange → red) rising from the
    /// bottom half of the screen, Live Voicemail-style. Purely decorative.
    private var gradeGradient: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(colors: [.green, .orange, .red],
                           startPoint: .leading, endPoint: .trailing)
                .scaleEffect(x: 1.7, y: 1.4)   // push the blur's faded edges offscreen
                .blur(radius: 60)
                .opacity(0.38)
                .mask(LinearGradient(colors: [.clear, .black],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: 400)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Live transcript, Live Voicemail-style: big bold text floating on the
    /// screen (no card), finalized phrases as paragraphs, the in-progress tail
    /// dimmed, auto-scrolled so the newest words stay visible.
    private var liveTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if recorder.liveFinal.isEmpty && recorder.liveVolatile.isEmpty {
                        Text("Listening…")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    } else {
                        (Text(recorder.liveFinal)
                         + Text(recorder.liveFinal.isEmpty || recorder.liveVolatile.isEmpty ? "" : "\n\n")
                         + Text(recorder.liveVolatile).foregroundColor(.secondary))
                            .font(.title3.weight(.semibold))
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("live-bottom")
                }
                .padding(.horizontal, 24)
            }
            .frame(maxHeight: 200)
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.12),
                                       .init(color: .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
            .onChange(of: recorder.liveFinal) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("live-bottom", anchor: .bottom)
                }
            }
            .onChange(of: recorder.liveVolatile) {
                proxy.scrollTo("live-bottom", anchor: .bottom)
            }
        }
    }

    /// Idle → big red record button (Voice Memos style).
    private var idleRecordButton: some View {
        Button(action: toggleRecording) {
            ZStack {
                Circle()
                    .fill(.red)
                    .frame(width: 88, height: 88)
                Image(systemName: "mic.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel("Start recording")
    }

    /// Recording → Pause/Resume (glass) + Stop (red square).
    private var recordingControls: some View {
        HStack(spacing: 44) {
            Button { recorder.togglePause() } label: {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 24))
                    .frame(width: 64, height: 64)
            }
            .glassButton()
            .clipShape(Circle())
            .accessibilityLabel(recorder.isPaused ? "Resume" : "Pause")

            Button(action: finishRecording) {
                ZStack {
                    Circle()
                        .strokeBorder(.red.opacity(0.35), lineWidth: 4)
                        .frame(width: 74, height: 74)
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.red)
                        .frame(width: 30, height: 30)
                }
            }
            .accessibilityLabel("Stop recording")
        }
        .padding(.top, 8)
    }

    /// Stopped, ready to analyze.
    @ViewBuilder
    private func finishedControls(url: URL) -> some View {
        VStack(spacing: 14) {
            switch processor.stage {
            case .done:
                Button("View feedback") { showFeedback = true }
                    .glassButton(prominent: true)
            case .error(let message):
                Text(message).font(.callout).foregroundStyle(.red)
                Button("Try again") { processor.reset() }
                    .glassButton()
            default:
                if !ModelDownloader.shared.isDownloaded {
                    modelHint
                }
                Button("Transcribe & analyze") { runProcessing(url: url) }
                    .glassButton(prominent: true)
                    .disabled(rubric == nil)
                Button("Record again") {
                    recorder.deleteRecording(url)
                    processor.reset()
                }
                .glassButton()
                if rubric == nil {
                    Text("Rubric not bundled — check project resources.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private var modelHint: some View {
        Label {
            Text("The AI model isn't downloaded yet. Download it in **Settings**, or tap Analyze to download now (~4.3 GB, one time).")
        } icon: {
            Image(systemName: "arrow.down.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Processing section (live rubric)

    @ViewBuilder
    private var processingSection: some View {
        switch processor.stage {
        case .transcribing:
            centeredProgress("Transcribing on-device…")
        case .identifyingSpeakers:
            centeredProgress("Identifying speakers…")
        case .redacting:
            centeredProgress("Removing identifiers…")
        case .preparingModel(let fraction):
            VStack(spacing: 12) {
                Spacer()
                ProgressView(value: fraction).frame(maxWidth: 260)
                Text(fraction < 0.001 ? "Preparing AI model…"
                                      : "Downloading AI model (one time)… \(Int(fraction * 100))%")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        case .scoring(let done, let total):
            VStack(spacing: 8) {
                Text("Analyzing the consultation")
                    .font(.headline)
                Text("\(done) of \(total) checked")
                    .font(.caption).foregroundStyle(.secondary)
                if let rubric {
                    LiveScoringView(rubric: rubric, results: processor.liveResults)
                }
            }
        case .summarizing:
            VStack(spacing: 8) {
                if let rubric {
                    LiveScoringView(rubric: rubric, results: processor.liveResults)
                }
                ProgressView("Writing summary…").padding(.bottom)
            }
        default:
            EmptyView()
        }
    }

    private func centeredProgress(_ title: String) -> some View {
        VStack {
            Spacer()
            ProgressView(title)
            Spacer()
        }
    }

    // MARK: - Actions

    private func runProcessing(url: URL) {
        guard let rubric else { return }
        Task {
            await processor.process(url: url, rubric: rubric)
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
                showFeedback = true
            }
        }
    }

    private func toggleRecording() {
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

    /// Stop and finalize the recording (ready to analyze).
    private func finishRecording() {
        recorder.toggle()
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

#Preview {
    RecordingView(location: .outpatientClinic)
}
