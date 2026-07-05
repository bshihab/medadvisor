import ActivityKit
import WidgetKit
import SwiftUI

/// Live Activity for the AI-model download. Compact: a circular progress ring
/// on the Lock Screen and in the Dynamic Island (like a download indicator),
/// plus a clean glyph + line in the expanded island.
struct ModelDownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ModelDownloadAttributes.self) { context in
            lockScreen(context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("AI model", systemImage: "brain.head.profile")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    statusText(context.state).font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Image(systemName: context.state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(context.state.finished ? .green : .blue)
                        line(context.state)
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: "brain.head.profile").foregroundStyle(.blue)
            } compactTrailing: {
                ring(context.state, size: 20, lineWidth: 2.5, glyph: false)
            } minimal: {
                ring(context.state, size: 20, lineWidth: 2.5, glyph: false)
            }
            .keylineTint(.blue)
        }
    }

    // MARK: - Lock Screen (compact row: ring + text + %)

    private func lockScreen(_ s: ModelDownloadAttributes.ContentState) -> some View {
        HStack(spacing: 14) {
            ring(s, size: 42, lineWidth: 4, glyph: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.finished ? "AI model ready" : "Downloading AI model")
                    .font(.subheadline.weight(.semibold))
                Text(s.finished ? "MedAdvisor · ready to score" : "MedAdvisor · runs on your device")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            statusText(s).font(.title3.weight(.bold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Pieces

    /// Circular progress ring, optionally with a glyph in the center.
    @ViewBuilder
    private func ring(_ s: ModelDownloadAttributes.ContentState,
                      size: CGFloat, lineWidth: CGFloat, glyph: Bool) -> some View {
        let tint: Color = s.finished ? .green : .blue
        ZStack {
            Circle().stroke(Color.primary.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: s.finished ? 1 : max(0.03, s.progress))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if glyph {
                Image(systemName: s.finished ? "checkmark" : "arrow.down")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
    }

    /// Thin rounded progress line.
    private func line(_ s: ModelDownloadAttributes.ContentState) -> some View {
        ProgressView(value: s.finished ? 1 : s.progress)
            .tint(s.finished ? .green : .blue)
    }

    private func statusText(_ s: ModelDownloadAttributes.ContentState) -> some View {
        Text(s.finished ? "Done" : "\(Int((s.progress * 100).rounded()))%")
            .monospacedDigit()
            .foregroundStyle(s.finished ? .green : .blue)
    }
}
