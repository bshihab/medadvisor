import SwiftUI

/// M0 UI: a clean start/stop control with a live input-level meter and elapsed time.
/// Proves on-device capture works (verify in airplane mode).
struct RecordingView: View {
    @StateObject private var recorder = AudioRecorder()

    var body: some View {
        VStack(spacing: 40) {
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

            Spacer()

            if !recorder.recordings.isEmpty {
                Text("\(recorder.recordings.count) recording(s) saved on device")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear { recorder.requestPermission() }
        .alert("Microphone access needed",
               isPresented: $recorder.permissionDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable microphone access in Settings to record consultations.")
        }
    }

    private var recordButton: some View {
        Button(action: recorder.toggle) {
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
