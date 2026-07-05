import ActivityKit
import WidgetKit
import SwiftUI

/// Live Activity for the AI-model download. A thick circular ring in the compact
/// island, and a "route"-style progress line (like the delivery/rideshare
/// activities) in the expanded island — with bold text and generous insets so
/// nothing sits on the rounded edges.
struct ModelDownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ModelDownloadAttributes.self) { context in
            lockScreen(context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("AI model", systemImage: "brain.head.profile")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.blue)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    badge(context.state).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.state.finished ? "Model ready" : "Downloading AI model")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.primary)
                        route(context.state)
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.blue)
            } compactTrailing: {
                ring(context.state, size: 18, lineWidth: 3.5, glyph: false)
            } minimal: {
                ring(context.state, size: 18, lineWidth: 3.5, glyph: false)
            }
            .keylineTint(.blue)
        }
    }

    // MARK: - Lock Screen (ring + text + %)

    private func lockScreen(_ s: ModelDownloadAttributes.ContentState) -> some View {
        HStack(spacing: 14) {
            ring(s, size: 44, lineWidth: 5, glyph: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.finished ? "AI model ready" : "Downloading AI model")
                    .font(.subheadline.weight(.bold))
                Text(s.finished ? "MedAdvisor · ready to score" : "MedAdvisor · runs on your device")
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            statusText(s).font(.title3.weight(.bold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Pieces

    /// Thick circular progress ring, optionally with a glyph in the center.
    @ViewBuilder
    private func ring(_ s: ModelDownloadAttributes.ContentState,
                      size: CGFloat, lineWidth: CGFloat, glyph: Bool) -> some View {
        let tint: Color = s.finished ? .green : .blue
        ZStack {
            Circle().stroke(Color.primary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: s.finished ? 1 : max(0.04, s.progress))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if glyph {
                Image(systemName: s.finished ? "checkmark" : "arrow.down")
                    .font(.system(size: size * 0.34, weight: .heavy))
                    .foregroundStyle(tint)
            }
        }
        // Keep the centered stroke inside the frame so it can't clip against the
        // compact Dynamic Island edges.
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
    }

    /// "Route" line: a start glyph, a progress track with a moving dot, and a
    /// destination glyph — like the delivery/rideshare Live Activities.
    private func route(_ s: ModelDownloadAttributes.ContentState) -> some View {
        let p = s.finished ? 1 : min(1, max(0, s.progress))
        let tint: Color = s.finished ? .green : .blue
        return HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.footnote).foregroundStyle(.blue)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.2)).frame(height: 5)
                    Capsule().fill(tint).frame(width: w * p, height: 5)
                    Circle().fill(.white)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(tint, lineWidth: 3))
                        .offset(x: min(w - 11, max(0, w * p - 5.5)))
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 12)
            Image(systemName: s.finished ? "checkmark.seal.fill" : "brain.head.profile")
                .font(.footnote).foregroundStyle(s.finished ? .green : .secondary)
        }
    }

    /// Percentage in a tinted capsule (like the time badges in the examples).
    private func badge(_ s: ModelDownloadAttributes.ContentState) -> some View {
        statusText(s)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill((s.finished ? Color.green : Color.blue).opacity(0.22)))
    }

    private func statusText(_ s: ModelDownloadAttributes.ContentState) -> some View {
        Text(s.finished ? "Done" : "\(Int((s.progress * 100).rounded()))%")
            .monospacedDigit()
            .foregroundStyle(s.finished ? .green : .blue)
    }
}
