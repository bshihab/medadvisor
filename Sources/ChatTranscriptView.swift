import SwiftUI

/// Renders speaker-labeled turns in the SAME style as the live transcription
/// screen: a small speaker label in the left gutter and the phrase as large
/// semibold text — not iMessage bubbles. Sits over a soft ombre.
struct ChatTranscriptView: View {
    let turns: [TranscriptTurn]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(turn.speaker)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(color(for: turn.speaker))
                            .frame(width: 64, alignment: .leading)
                        Text(turn.text)
                            .font(.title3.weight(.semibold))
                            .lineSpacing(3)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// Distinct color per speaker so the left gutter reads at a glance.
    private func color(for speaker: String) -> Color {
        switch speaker.lowercased() {
        case "doctor":  return .blue
        case "patient": return .purple
        default:        return .secondary
        }
    }
}
