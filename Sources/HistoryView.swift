import SwiftUI

/// Lists saved feedback (encrypted at rest) as color-coded cards and opens any
/// past consultation with both the feedback and the full transcript.
/// Uses a ScrollView (not a List) so rows only scroll vertically — no
/// swipe-to-delete gesture. Delete is via long-press.
struct HistoryView: View {
    @ObservedObject private var store = FeedbackStore.shared
    @State private var selected: ConsultationRecord?

    var body: some View {
        Group {
            if store.records.isEmpty {
                ContentUnavailableView(
                    "No saved feedback yet",
                    systemImage: "waveform",
                    description: Text("Record a consultation to see it here."))
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(store.records) { record in
                            Button { selected = record } label: { card(record) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        store.delete(record)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("History")
        .ambientGradient([.indigo, .purple, .pink])
        .sheet(item: $selected) { record in
            if let location = record.location, let rubric = RubricLoader.load(for: location) {
                FeedbackView(feedback: record.feedback, rubric: rubric,
                             transcript: record.transcript, turns: record.turns)
            }
        }
    }

    private func card(_ record: ConsultationRecord) -> some View {
        let f = record.feedback
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(record.locationRaw)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text(ScoreBand.label(f.metFraction))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ScoreBand.color(f.metFraction))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(ScoreBand.color(f.metFraction).opacity(0.15), in: Capsule())
            }

            ScoreBar(met: f.metCount, partial: f.partialCount, missed: f.missedCount)
                .frame(height: 8)

            HStack {
                Text(record.date, format: .dateTime.month().day().hour().minute())
                Spacer()
                Text("\(f.metCount)/\(f.total) done")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
    }
}
