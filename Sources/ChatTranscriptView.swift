import SwiftUI

/// Renders speaker-labeled turns as a two-sided chat (iMessage style):
/// the first speaker on the left, the other on the right. Bubbles use Liquid
/// Glass on iOS 26 (tinted for the second speaker) with a material fallback.
struct ChatTranscriptView: View {
    let turns: [TranscriptTurn]

    private var firstSpeaker: String? { turns.first?.speaker }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                    let showName = index == 0 || turns[index - 1].speaker != turn.speaker
                    bubble(turn, showName: showName)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func bubble(_ turn: TranscriptTurn, showName: Bool) -> some View {
        let isLeft = (turn.speaker == firstSpeaker)
        HStack(alignment: .bottom, spacing: 0) {
            if !isLeft { Spacer(minLength: 48) }

            VStack(alignment: isLeft ? .leading : .trailing, spacing: 3) {
                if showName {
                    Text(turn.speaker)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
                Text(turn.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .foregroundStyle(isLeft ? Color.primary : Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .bubbleBackground(isLeft: isLeft, shape: bubbleShape(isLeft: isLeft))
            }

            if isLeft { Spacer(minLength: 48) }
        }
        .padding(isLeft ? .trailing : .leading, 8)
    }

    private func bubbleShape(isLeft: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: isLeft ? 6 : 20,
            bottomTrailingRadius: isLeft ? 20 : 6,
            topTrailingRadius: 20)
    }
}

private extension View {
    /// Liquid Glass bubble on iOS 26 (tinted for the patient side); material +
    /// accent fallback below.
    @ViewBuilder
    func bubbleBackground(isLeft: Bool, shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            if isLeft {
                self.glassEffect(.regular, in: shape)
            } else {
                self.glassEffect(.regular.tint(.accentColor), in: shape)
            }
        } else {
            self.background(
                isLeft ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.accentColor),
                in: shape)
        }
    }
}
