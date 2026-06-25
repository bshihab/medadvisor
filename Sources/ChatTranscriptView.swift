import SwiftUI

/// Renders speaker-labeled turns as a two-sided chat (iMessage style):
/// the first speaker on the left, the other on the right.
struct ChatTranscriptView: View {
    let turns: [TranscriptTurn]

    private var firstSpeaker: String? { turns.first?.speaker }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                    bubble(turn)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func bubble(_ turn: TranscriptTurn) -> some View {
        let isLeft = (turn.speaker == firstSpeaker)
        HStack(alignment: .bottom, spacing: 0) {
            if !isLeft { Spacer(minLength: 44) }

            VStack(alignment: isLeft ? .leading : .trailing, spacing: 2) {
                Text(turn.speaker)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(turn.text)
                    .textSelection(.enabled)   // long-press to select/copy
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        isLeft ? AnyShapeStyle(Color.secondary.opacity(0.15))
                               : AnyShapeStyle(Color.accentColor),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .foregroundStyle(isLeft ? Color.primary : Color.white)
            }

            if isLeft { Spacer(minLength: 44) }
        }
    }
}
