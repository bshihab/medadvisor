import SwiftUI

/// Lists saved feedback (encrypted at rest) and opens any past consultation.
struct HistoryView: View {
    @ObservedObject private var store = FeedbackStore.shared
    @State private var selected: ConsultationRecord?

    var body: some View {
        List {
            if store.records.isEmpty {
                Text("No saved feedback yet. Record a consultation to see it here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.records) { record in
                    Button {
                        selected = record
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.locationRaw).font(.headline)
                            HStack {
                                Text(record.date, style: .date)
                                Text(record.date, style: .time)
                                Spacer()
                                Text("\(metCount(record))/\(record.feedback.perCriterion.count) met")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
                .onDelete { offsets in
                    offsets.map { store.records[$0] }.forEach(store.delete)
                }
            }
        }
        .navigationTitle("History")
        .sheet(item: $selected) { record in
            if let location = record.location, let rubric = RubricLoader.load(for: location) {
                FeedbackView(feedback: record.feedback, rubric: rubric)
            }
        }
    }

    private func metCount(_ record: ConsultationRecord) -> Int {
        record.feedback.perCriterion.filter { $0.met }.count
    }
}
