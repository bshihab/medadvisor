import SwiftUI

/// Saved feedback (encrypted at rest) as color-coded cards. Tap to open;
/// swipe a row to delete or share it; or "Select" to delete/share several at
/// once without opening each.
struct HistoryView: View {
    @ObservedObject private var store = FeedbackStore.shared
    @State private var selected: ConsultationRecord?
    @State private var isSelecting = false
    @State private var picked = Set<String>()

    var body: some View {
        Group {
            if store.records.isEmpty {
                ContentUnavailableView(
                    "No saved feedback yet",
                    systemImage: "waveform",
                    description: Text("Record a consultation to see it here."))
            } else {
                list
            }
        }
        .navigationTitle("History")
        .toolbar { toolbarContent }
        .sheet(item: $selected) { record in
            if let location = record.location, let rubric = RubricLoader.load(for: location) {
                FeedbackView(feedback: record.feedback, rubric: rubric,
                             transcript: record.transcript, turns: record.turns)
            }
        }
    }

    private var list: some View {
        List {
            ForEach(store.records) { record in
                row(record)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { store.delete(record) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        ShareLink(item: shareText(record)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .tint(.indigo)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
    }

    private func row(_ record: ConsultationRecord) -> some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: picked.contains(record.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(picked.contains(record.id) ? Color.accentColor : .secondary)
                    .transition(.scale.combined(with: .opacity))
            }
            card(record)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting { toggle(record.id) } else { selected = record }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(isSelecting ? "Done" : "Select") {
                withAnimation(.smooth) {
                    isSelecting.toggle()
                    if !isSelecting { picked.removeAll() }
                }
            }
            .disabled(store.records.isEmpty)
        }
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .destructive) { deleteSelected() } label: {
                    Image(systemName: "trash")
                }
                .disabled(picked.isEmpty)
            }
            ToolbarItem(placement: .topBarLeading) {
                ShareLink(items: pickedRecords.map { shareText($0) }) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(picked.isEmpty)
            }
        }
    }

    // MARK: - Selection helpers

    private var pickedRecords: [ConsultationRecord] {
        store.records.filter { picked.contains($0.id) }
    }
    private func toggle(_ id: String) {
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }
    private func deleteSelected() {
        for record in pickedRecords { store.delete(record) }
        picked.removeAll()
        withAnimation(.smooth) { isSelecting = false }
    }

    /// Plain-text summary of one session for the share sheet.
    private func shareText(_ record: ConsultationRecord) -> String {
        let f = record.feedback
        var out = "MedAdvisor — \(record.locationRaw)\n"
        out += record.date.formatted(date: .abbreviated, time: .shortened) + "\n"
        out += "\(f.metCount)/\(f.total) done\n"
        if let summary = f.summary, !summary.isEmpty { out += "\n\(summary)\n" }
        return out
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
        .glassSurface(in: RoundedRectangle(cornerRadius: 16))
    }
}
