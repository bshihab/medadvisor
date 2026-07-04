import SwiftUI

/// A Voice Memos-style scrolling waveform: symmetric rounded bars for recent
/// audio levels, newest on the right, mirrored around the vertical center.
/// Bar heights animate with a gentle ease so the wave flows smoothly leftward
/// instead of snapping between samples.
struct WaveformView: View {
    let levels: [Float]
    var color: Color = .red
    var barCount: Int = 42

    var body: some View {
        GeometryReader { geo in
            let bars = displayBars(target: barCount)
            let spacing: CGFloat = 3
            let barWidth = max(2, (geo.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(bars.indices, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth,
                               height: max(barWidth, CGFloat(shape(bars[i])) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            // Ease each bar toward its neighbour's value → a smooth leftward flow.
            .animation(.easeOut(duration: 0.16), value: levels.count)
        }
    }

    /// Most-recent `target` levels, left-padded with zeros so the row is full
    /// and the waveform appears to scroll in from the right.
    private func displayBars(target: Int) -> [Float] {
        let recent = Array(levels.suffix(target))
        guard recent.count < target else { return recent }
        return Array(repeating: 0, count: target - recent.count) + recent
    }

    /// Perceptual boost so quiet speech still shows visible bars.
    private func shape(_ level: Float) -> Float {
        min(1, pow(level, 0.55))
    }
}
