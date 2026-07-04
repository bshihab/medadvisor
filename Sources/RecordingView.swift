import SwiftUI

/// Recording mode: record an encounter (pause/resume supported), then run the
/// full on-device pipeline (transcribe → attribute → score) with the rubric
/// filling in live, and show feedback.
struct RecordingView: View {
    let location: AppLocation
    /// When set, the idle screen shows a tappable location chip (opens the
    /// slide-up location picker on the home screen). nil = no chip.
    var onTapLocation: (() -> Void)? = nil

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

    /// The visible phase of the screen — drives a single fluid animation when we
    /// move between recording, the just-stopped buttons, processing, and done.
    private var phaseKey: String {
        switch processor.stage {
        case .done: return "done"
        case .error: return "error"
        default:
            if recorder.isRecording { return "recording" }
            if recorder.recordings.first != nil { return "finished" }
            return "idle"
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
        .animation(.smooth(duration: 0.38), value: phaseKey)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // fill the screen so
        .background { gradeGradient }                        // the glow spans edge-to-edge
        .navigationTitle(location.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            recorder.requestPermission()
            processor.requestPermissions()
        }
        .sheet(isPresented: $showFeedback, onDismiss: {
            // Back to a fresh record screen (the record button), not stuck on
            // the finished "View feedback" state.
            processor.reset()
        }) {
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
        Text(timeString(shownTime))
            .font(.system(size: 56, weight: .light, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(recorder.isRecording ? .primary : .secondary)
            .contentTransition(.numericText())

        if reviewPhase {
            finishedControls
        } else if recorder.isRecording {
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
            if let onTapLocation {
                Button(action: onTapLocation) {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.circle.fill")
                        Text(location.rawValue).fontWeight(.semibold)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .tint(.primary)
            }
            idleRecordButton
            Text("Tap to record the consultation")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// Soft grading-palette gradient (green → orange → red) rising from the
    /// bottom of the screen, Live Voicemail-style. While recording it becomes
    /// alive: it swells and brightens with the mic level and drifts slowly, so
    /// louder speech visibly pushes the glow outward. Calm/static when idle.
    private var gradeGradient: some View {
        Group {
            if recorder.isRecording && !recorder.isPaused {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let lvl = CGFloat(max(0, min(1, recorder.level)))
                    // Swell + brighten with volume; drift amplitude also grows
                    // with volume so louder speech moves the glow more. Tunable.
                    gradientLayer(scaleX: 1.7 + lvl * 0.5,
                                  scaleY: 1.4 + lvl * 0.7,
                                  opacity: 0.34 + Double(lvl) * 0.30,
                                  dx: CGFloat(sin(t * 0.8)) * (16 + lvl * 42),
                                  dy: CGFloat(cos(t * 0.6)) * (8 + lvl * 22))
                        .animation(.easeOut(duration: 0.18), value: lvl)
                }
            } else {
                gradientLayer(scaleX: 1.7, scaleY: 1.4, opacity: 0.38, dx: 0, dy: 0)
            }
        }
    }

    /// The gradient layer itself, parameterized so idle (static) and recording
    /// (level-driven) states share one definition.
    private func gradientLayer(scaleX: CGFloat, scaleY: CGFloat,
                               opacity: Double, dx: CGFloat, dy: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(colors: [.green, .orange, .red],
                           startPoint: .leading, endPoint: .trailing)
                .scaleEffect(x: scaleX, y: scaleY)   // push the blur's faded edges offscreen
                .blur(radius: 60)
                .opacity(opacity)
                .offset(x: dx, y: dy)
                .mask(LinearGradient(colors: [.clear, .black],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: 400)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Live transcript, Live Voicemail-style: big bold text with a timestamp
    /// column on the left (the gaps between timestamps reveal the pauses), the
    /// in-progress tail dimmed, auto-scrolled so the newest words stay visible.
    private var liveTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if recorder.liveLines.isEmpty && recorder.liveVolatile.isEmpty {
                        Text("Listening…")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(recorder.liveLines) { line in
                            liveRow(time: line.time, text: line.text, dimmed: false)
                        }
                        if !recorder.liveVolatile.isEmpty {
                            liveRow(time: recorder.elapsed, text: recorder.liveVolatile, dimmed: true)
                        }
                    }
                    Color.clear.frame(height: 1).id("live-bottom")
                }
                .padding(.horizontal, 20)
            }
            .frame(maxHeight: 220)
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.12),
                                       .init(color: .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
            .onChange(of: recorder.liveLines.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("live-bottom", anchor: .bottom)
                }
            }
            .onChange(of: recorder.liveVolatile) {
                proxy.scrollTo("live-bottom", anchor: .bottom)
            }
        }
    }

    /// One live-transcript line: mm:ss timestamp on the left, phrase on the right.
    private func liveRow(time: TimeInterval, text: String, dimmed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timeString(time))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(dimmed ? .tertiary : .secondary)
                .frame(width: 46, alignment: .trailing)
            Text(text)
                .font(.title3.weight(.semibold))
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// True while the analyze screen (or the finished feedback) should show
    /// instead of the recording controls.
    private var reviewPhase: Bool {
        if case .done = processor.stage { return true }
        if case .error = processor.stage { return true }
        return !recorder.isRecording && recorder.recordings.first != nil
    }

    /// The timer value to show: live while recording, the recorded length once
    /// stopped, 00:00 when idle.
    private var shownTime: TimeInterval {
        if recorder.isRecording { return recorder.elapsed }
        if reviewPhase { return recorder.lastDuration }
        return 0
    }

    /// Stopped for review, ready to analyze (or done/errored).
    @ViewBuilder
    private var finishedControls: some View {
        VStack(spacing: 16) {
            switch processor.stage {
            case .done:
                Button("View feedback") { showFeedback = true }
                    .glassButton(prominent: true)
                    .controlSize(.large)
            case .error(let message):
                Text(message).font(.callout).foregroundStyle(.red)
                Button("Try again") { processor.reset() }
                    .glassButton()
            default:
                // Preview the transcript captured so far before committing.
                if !recorder.liveLines.isEmpty { reviewTranscript }

                if !ModelDownloader.shared.isDownloaded {
                    modelHint
                }
                // Primary action — big, full-width, hard to miss.
                Button {
                    if let url = recorder.recordings.first { runProcessing(url: url) }
                } label: {
                    Label("Transcribe & analyze", systemImage: "sparkles")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .glassButton(prominent: true)
                .controlSize(.large)
                .disabled(rubric == nil)

                // Secondary action — discard and start over.
                Button("Record again") {
                    if let url = recorder.recordings.first { recorder.deleteRecording(url) }
                    processor.reset()
                }
                .font(.callout.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if rubric == nil {
                    Text("Rubric not bundled — check project resources.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// The transcript captured while recording (Apple engine), in the same
    /// timestamped live-transcript style, for a quick review before analyzing.
    private var reviewTranscript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(recorder.liveLines) { line in
                    liveRow(time: line.time, text: line.text, dimmed: false)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 260)
        .mask(
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black, location: 0.08),
                                   .init(color: .black, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        )
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
            ProcessingWave(title: title)
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

    /// The red Stop button: stop and finalize the recording (ready to analyze).
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
