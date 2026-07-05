import ActivityKit
import WidgetKit
import SwiftUI

/// Live Activity for the AI-model download: Lock Screen banner + Dynamic Island,
/// so the user can leave the app and watch the download progress.
struct ModelDownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ModelDownloadAttributes.self) { context in
            lockScreen(context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.state.finished ? "Ready" : "AI model")
                    } icon: {
                        Image(systemName: context.state.finished ? "checkmark.circle.fill" : "arrow.down.circle")
                    }
                    .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.finished ? "Done" : "\(percent(context.state.progress))%")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: context.state.progress)
                            .tint(.blue)
                        Text(context.state.finished ? "AI model downloaded — ready to score."
                                                     : "Downloading AI model…")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.finished ? "checkmark.circle.fill" : "arrow.down.circle")
            } compactTrailing: {
                Text("\(percent(context.state.progress))%")
                    .font(.caption2).monospacedDigit()
            } minimal: {
                Image(systemName: context.state.finished ? "checkmark.circle.fill" : "arrow.down.circle")
            }
            .keylineTint(.blue)
        }
    }

    @ViewBuilder
    private func lockScreen(_ state: ModelDownloadAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: state.finished ? "checkmark.circle.fill" : "brain.head.profile")
                    .foregroundStyle(.blue)
                Text(state.finished ? "AI model ready" : "Downloading AI model")
                    .font(.headline)
                Spacer()
                Text(state.finished ? "Done" : "\(percent(state.progress))%")
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: state.progress).tint(.blue)
            Text("MedAdvisor · runs on your device")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func percent(_ p: Double) -> Int { Int((p * 100).rounded()) }
}
