import SwiftUI

/// Pulsing waveform bars — used while the recording is being transcribed /
/// speakers identified / redacted (before the rubric's check-mark animation).
/// The bars undulate in a travelling wave, tinted with the grade palette.
struct ProcessingWave: View {
    var colors: [Color] = [.green, .orange, .red]
    var title: String
    private let bars = 5

    var body: some View {
        VStack(spacing: 22) {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 7) {
                    ForEach(0..<bars, id: \.self) { i in
                        Capsule()
                            .fill(LinearGradient(colors: colors,
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 9, height: barHeight(i, t))
                    }
                }
                .frame(height: 64, alignment: .center)
            }
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .animation(.easeInOut, value: title)
        }
    }

    private func barHeight(_ i: Int, _ t: Double) -> CGFloat {
        let phase = t * 3.2 + Double(i) * 0.6
        return CGFloat(16 + 30 * (0.5 + 0.5 * sin(phase)))
    }
}

/// Rotating gradient ring with a breathing sparkle core — used while Insights
/// is being generated. Deliberately different from ProcessingWave; tinted with
/// the Insights palette.
struct GeneratingPulse: View {
    var colors: [Color] = [.teal, .blue, .indigo]
    var title: String

    var body: some View {
        VStack(spacing: 22) {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let rotation = Angle.degrees((t * 110).truncatingRemainder(dividingBy: 360))
                let pulse = CGFloat(0.82 + 0.18 * sin(t * 2.2))
                ZStack {
                    Circle()
                        .trim(from: 0, to: 0.72)
                        .stroke(
                            AngularGradient(colors: colors + [colors.first ?? .blue],
                                            center: .center),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 56, height: 56)
                        .rotationEffect(rotation)
                    Image(systemName: "sparkles")
                        .font(.system(size: 22))
                        .foregroundStyle(LinearGradient(colors: colors,
                                                        startPoint: .top, endPoint: .bottom))
                        .scaleEffect(pulse)
                }
                .frame(height: 64)
            }
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
