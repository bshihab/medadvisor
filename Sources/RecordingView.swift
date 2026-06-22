import SwiftUI

/// M0 UI: a clean start/stop control with a live input-level meter and elapsed time.
/// Proves on-device capture works (verify in airplane mode).
struct RecordingView: View {
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var transcriber = SpeechTranscriber()
    @StateObject private var analyzer = ConsultationAnalyzer()
    @State private var showFeedback = false

    // Placeholder rubric until baba's real mark schemes arrive (M1).
    private let rubric = RubricLoader.load(named: "example-spikes-breaking-bad-news")

    var body: some View {
        VStack(spacing: 32) {
            Text("MedAdvisor")
                .font(.largeTitle.bold())

            Spacer()

            LevelMeter(level: recorder.level)
                .frame(height: 12)
                .padding(.horizontal, 40)

            Text(timeString(recorder.elapsed))
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(.secondary)

            recordButton

            transcriptSection

            Spacer()

            if !recorder.recordings.isEmpty {
                Text("\(recorder.recordings.count) recording(s) saved on device")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear {
            recorder.requestPermission()
            transcriber.requestPermission()
        }
        .sheet(isPresented: $showFeedback) {
            if case .done(let feedback) = analyzer.state, let rubric {
                FeedbackView(feedback: feedback, rubric: rubric)
            }
        }
        .alert("Microphone access needed",
               isPresented: $recorder.permissionDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable microphone access in Settings to record consultations.")
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if let latest = recorder.recordings.first, !recorder.isRecording {
            switch transcriber.state {
            case .idle:
                Button("Transcribe on-device") { transcriber.transcribe(url: latest) }
                    .buttonStyle(.bordered)
            case .transcribing:
                ProgressView("Transcribing on-device…")
            case .done(let text):
                VStack(spacing: 12) {
                    ScrollView {
                        Text(text.isEmpty ? "(no speech detected)" : text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .frame(maxHeight: 160)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    analyzeControls(transcript: text)
                }
                .padding(.horizontal)
            case .unavailable(let reason):
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func analyzeControls(transcript: String) -> some View {
        switch analyzer.state {
        case .idle:
            Button("Analyze consultation") {
                guard let rubric else { return }
                Task {
                    await analyzer.analyze(transcript: transcript, rubric: rubric)
                    if case .done = analyzer.state { showFeedback = true }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(rubric == nil)
            if rubric == nil {
                Text("Rubric not bundled — check project resources.")
                    .font(.caption).foregroundStyle(.red)
            }
        case .redacting:
            ProgressView("Removing identifiers…")
        case .analyzing:
            ProgressView("Analyzing on-device… (this can take a bit)")
        case .done:
            Button("View feedback") { showFeedback = true }
                .buttonStyle(.borderedProminent)
        case .error(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

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
        if !recorder.isRecording {
            transcriber.reset()   // clear any previous transcript before a new take
            analyzer.reset()
        }
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
    RecordingView()
}
