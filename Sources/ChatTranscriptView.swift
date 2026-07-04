import SwiftUI

/// Renders speaker-labeled turns in the live-transcription text style (large
/// semibold text, no iMessage bubbles), but split by side: the Doctor's turns
/// hug the LEFT of the screen and the Patient's hug the RIGHT, each with a small
/// colored speaker label, so the two roles read at a glance from opposite sides.
struct ChatTranscriptView: View {
    let turns: [TranscriptTurn]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                    turnRow(turn)
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func turnRow(_ turn: TranscriptTurn) -> some View {
        let isPatient = turn.speaker.lowercased() == "patient"
        VStack(alignment: isPatient ? .trailing : .leading, spacing: 4) {
            Text(turn.speaker)
                .font(.caption.weight(.bold))
                .foregroundStyle(isPatient ? Color.purple : Color.blue)
            Text(turn.text)
                .font(.title3.weight(.semibold))
                .lineSpacing(3)
                .foregroundStyle(.primary)
                .multilineTextAlignment(isPatient ? .trailing : .leading)
                .textSelection(.enabled)
        }
        // Hug the correct edge, leaving room on the opposite side so the two
        // speakers visibly come from left vs right.
        .frame(maxWidth: .infinity, alignment: isPatient ? .trailing : .leading)
        .padding(isPatient ? .leading : .trailing, 44)
    }
}
