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
    @State private var savedRecord: ConsultationRecord?
    @State private var consentConfirmed = false
    @State private var showConsentDialog = false

    private var rubric: Rubric? { RubricLoader.load(for: location) }
    /// Whether the ACTIVE engine's model is present — llama needs the downloaded
    /// GGUF; Core AI's model ships inside the app bundle, so gating the record
    /// button on the 4.3GB download would demand a model that engine never reads.
    private var llmReady: Bool {
        guard LLMEngine.shared.requiresManagedDownload else {
            #if canImport(CoreAILanguageModels)
            return models.isInstalled(.coreAI)
            #else
            return true
            #endif
        }
        return models.isInstalled(.llm)
    }

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
                             turns: processor.transcriptTurns.isEmpty ? nil : processor.transcriptTurns,
                             record: savedRecord,
                             promptShareOnAppear: true)
            }
        }
        .alert("Microphone access needed", isPresented: $recorder.permissionDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable microphone access in Settings to record consultations.")
        }
        .alert("Couldn't start recording", isPresented: $recorder.startFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The microphone may be in use by another app or a phone call. Close it and try again.")
        }
        .alert("Patient consent", isPresented: $showConsentDialog) {
            Button("Cancel", role: .cancel) {}
            Button("The patient consents") {
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
            Text("Open Settings (the gear, top-right) and download the AI model — one time. Recording needs it to give feedback.")
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
    /// True while the pipeline is running (transcribe -> score -> summarize).
    private var isAnalyzing: Bool {
        switch processor.stage {
        case .idle, .done, .error: return false
        default: return true
        }
    }

    private var gradeGradient: some View {
        Group {
            if isAnalyzing {
                // Calm breathing for the whole pipeline: animates the SAME
                // internal parameters the recording variant drives (swell,
                // brightness, drift before the mask, on the over-scaled
                // canvas) so no edges ever show — but on a constant rhythm
                // instead of the mic, and via a repeatForever animation that
                // runs on the render server (immune to the pipeline stalling
                // the main thread, which froze the TimelineView attempts).
                CalmGlow()
            } else if recorder.isRecording && !recorder.isPaused {
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

                if !llmReady {
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
            Text("The AI model isn't downloaded yet. Open **Settings** (the gear, top-right) and download it (~4.3 GB, one time) before analyzing.")
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
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Text("Analyzing consultation").font(.title2.weight(.bold))
                Text(stageDetail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            PipelineStagesView(currentIndex: stageIndex)
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                .glassHairline(22)
                .padding(.horizontal)
            stageExtra
            Spacer(minLength: 0)
        }
        .animation(.smooth(duration: 0.35), value: stageIndex)
    }

    /// The pipeline runs transcribe → load model → speakers → score → summary.
    private var stageIndex: Int {
        switch processor.stage {
        case .transcribing:                     return 0
        case .preparingModel:                   return 1
        case .identifyingSpeakers, .redacting:  return 2
        case .scoring:                          return 3
        case .summarizing:                      return 4
        case .done:                             return 5
        default:                                return 0
        }
    }

    private var stageDetail: String {
        switch processor.stage {
        case .transcribing:            return "Transcribing on-device…"
        case .preparingModel(let f):   return f < 0.001 ? "Preparing the AI model…"
                                                          : "Downloading AI model… \(Int(f * 100))%"
        case .identifyingSpeakers:     return "Identifying who's speaking…"
        case .redacting:               return "Removing identifiers…"
        case .scoring(let d, let t):   return "Scoring — \(d) of \(t) checked"
        case .summarizing:             return "Writing the summary…"
        default:                       return ""
        }
    }

    @ViewBuilder
    private var stageExtra: some View {
        switch processor.stage {
        case .scoring, .summarizing:
            if let rubric {
                LiveScoringView(rubric: rubric, results: processor.liveResults)
            }
        case .preparingModel(let f) where f > 0.001:
            ProgressView(value: f).tint(.blue).frame(maxWidth: 260)
        default:
            EmptyView()
        }
    }

    private func centeredProgress(_ title: String) -> some View {
        // System spinner (UIKit-backed) rather than a custom SwiftUI animation:
        // on-device transcription saturates the chip and stalls custom animations,
        // but the system indicator keeps spinning because it runs off the main thread.
        VStack(spacing: 18) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    // MARK: - Actions

    private func runProcessing(url: URL) {
        guard let rubric else { return }
        Task {
            // Hand over the live transcript's pause-segmented lines — Apple's
            // streaming engine already split them at natural pauses (where
            // speakers change), which beats re-flattening the audio.
            await processor.process(url: url, rubric: rubric,
                                    liveSegments: recorder.liveLines.map(\.text))
            if case .done(let feedback) = processor.stage {
                let record = ConsultationRecord(
                    id: UUID().uuidString,
                    date: Date(),
                    locationRaw: location.rawValue,
                    transcript: processor.redactedTranscript,
                    turns: processor.transcriptTurns.isEmpty ? nil : processor.transcriptTurns,
                    feedback: feedback,
                    ownerUid: AccountStore.shared.uid)
                FeedbackStore.shared.add(record)
                savedRecord = record
                Task { await PrivateBackup.syncPending() }   // private cloud backup (D2 on by default)
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
        // Consent is per ENCOUNTER: require a fresh confirmation before the next
        // recording rather than carrying one Accept across every patient this
        // session. (Pause/resume within a recording never re-prompt.)
        consentConfirmed = false
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

#Preview {
    RecordingView(location: .outpatientClinic)
}

/// A washing-machine-style multi-stage progress bar for the analysis pipeline:
/// each stage is a glyph chip — completed ones show a checkmark, the current one
/// pulses, upcoming ones are dim.
struct PipelineStagesView: View {
    let currentIndex: Int
    @State private var pulse = false

    private let stages: [(icon: String, label: String)] = [
        ("waveform", "Transcribe"),
        ("brain.head.profile", "AI model"),
        ("person.2.fill", "Speakers"),
        ("checklist", "Score"),
        ("sparkles", "Summary"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.offset) { i, s in
                chip(icon: s.icon, label: s.label, index: i)
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear { pulse = true }
    }

    @ViewBuilder
    private func chip(icon: String, label: String, index: Int) -> some View {
        let done = index < currentIndex
        let current = index == currentIndex
        let fill: Color = (done || current) ? .blue : Color.primary.opacity(0.12)
        let fg: Color = (done || current) ? .white : .secondary
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(fill).frame(width: 36, height: 36)
                Image(systemName: done ? "checkmark" : icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(fg)
            }
            .scaleEffect(current && pulse ? 1.12 : 1)
            .animation(current ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                               : .default, value: pulse)
            Text(label)
                .font(.caption2.weight(current ? .bold : .medium))
                .foregroundStyle(current ? .primary : .secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}


/// The gradient layer, parameterized so idle (static), recording
/// (level-driven), and analyzing (CalmGlow) states share one definition.
/// The scale/offset happen BEFORE the soft mask on an over-scaled canvas,
/// so motion never exposes an edge.
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

/// The analyzing state's glow: breathes between two parameter sets of the
/// SAME layer the recording state animates — swell, brightness, gentle
/// sideways drift — on a constant rhythm. repeatForever = render-server
/// animation, so it keeps breathing while the pipeline hammers the main
/// thread. Scale never dips below the recording baseline (1.7/1.4), so the
/// canvas always over-fills the screen and no black edges can appear.
private struct CalmGlow: View {
    @State private var breathing = false

    var body: some View {
        gradientLayer(scaleX: breathing ? 2.05 : 1.7,
                      scaleY: breathing ? 1.75 : 1.4,
                      opacity: breathing ? 0.50 : 0.30,
                      dx: breathing ? 26 : -26,
                      dy: breathing ? -10 : 10)
            .onAppear {
                withAnimation(.easeInOut(duration: 3.6).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}
