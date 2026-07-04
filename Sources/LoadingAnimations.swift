import SwiftUI

/// Apple-style audio activity bars — uniform accent-colored bars that pulse
/// symmetrically, like the system voice/audio indicator (no rainbow). Shown
/// while transcribing / identifying speakers / redacting. Uses repeatForever
/// animations (driven by the render server, off the main thread) so it stays
/// smooth even while the speech model is doing heavy work.
struct ProcessingWave: View {
    var tint: Color = .accentColor
    var title: String
    private let bars = 5
    @State private var animate = false

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 6) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(tint)
                        .frame(width: 6, height: 26)
                        .scaleEffect(y: animate ? 1.0 : 0.28, anchor: .center)
                        .animation(.easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.13), value: animate)
                }
            }
            .frame(height: 56)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .onAppear { animate = true }
    }
}

/// "Insights forming" — a little bar chart whose bars grow/settle and a couple
/// of skeleton table rows, so it reads like a graph + table being built rather
/// than a generic spinner. repeatForever → smooth and off the main thread.
struct GeneratingInsights: View {
    var tint: Color = .accentColor
    var title: String
    @State private var grow = false
    private let heights: [CGFloat] = [0.5, 0.85, 0.35, 0.7, 0.95]

    var body: some View {
        VStack(spacing: 18) {
            // Forming bar chart.
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(0..<heights.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint.opacity(0.85))
                        .frame(width: 16, height: 58 * (grow ? heights[i] : 0.08))
                        .animation(.easeInOut(duration: 0.7)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.1), value: grow)
                }
            }
            .frame(height: 58, alignment: .bottom)

            // Forming table rows (skeleton).
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(Color.secondary.opacity(grow ? 0.28 : 0.08))
                        .frame(width: 170 - CGFloat(i) * 30, height: 8)
                        .animation(.easeInOut(duration: 0.9)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15), value: grow)
                }
            }

            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .onAppear { grow = true }
    }
}
