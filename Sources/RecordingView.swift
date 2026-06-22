import SwiftUI

/// M0 UI: a clean start/stop control with a live input-level meter and elapsed time.
/// Proves on-device capture works (verify in airplane mode).
struct RecordingView: View {
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var transcriber = SpeechTranscriber()

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
                ScrollView {
                    Text(text.isEmpty ? "(no speech detected)" : text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(maxHeight: 180)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            case .unavailable(let reason):
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
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
