import SwiftUI

/// The Progress hub — one scroll that combines Insights, Goals, and History
/// (which used to be three separate tabs). Each section shows a compact summary
/// inline and links out to the full screen for detail, so nothing is lost.
struct ProgressHome: View {
    @ObservedObject private var store = FeedbackStore.shared
    @ObservedObject private var notesStore = NotesStore.shared
    @ObservedObject private var account = AccountStore.shared
    @StateObject private var insights = InsightsEngine()
    @ObservedObject private var goals = GoalStore.shared
    @AppStorage("lastLocation") private var locationRaw = AppLocation.outpatientClinic.rawValue
    @State private var selected: ConsultationRecord?
    @State private var deleteTarget: ConsultationRecord?

    private var location: AppLocation { AppLocation(rawValue: locationRaw) ?? .outpatientClinic }
    private var recent: [ConsultationRecord] { Array(store.visibleRecords.prefix(4)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    insightsSection
                    goalsSection
                    if account.org != nil && !(notesStore.notes.isEmpty && notesStore.unreadCount == 0) {
                        notesSection
                    }
                    historySection
                }
                .padding()
            }
            .navigationTitle("Progress")
            .ambientGradient([.blue, .indigo, .purple])
            .settingsGear()
            .sheet(item: $selected) { record in
                if let loc = record.location, let rubric = RubricLoader.load(for: loc) {
                    FeedbackView(feedback: record.feedback, rubric: rubric,
                                 transcript: record.transcript, turns: record.turns,
                                 record: record)
                }
            }
            .onAppear { insights.loadSaved() }
            .task { await NotesStore.shared.refresh() }
            .deleteSessionDialog(target: $deleteTarget)
        }
    }

    // MARK: - Insights

    @ViewBuilder private var insightsSection: some View {
        NavigationLink { InsightsView() } label: {
            sectionCard(title: "Insights", systemImage: "sparkles") {
                if let i = insights.latest {
                    VStack(alignment: .leading, spacing: 8) {
                        if let imp = i.improvementPoints {
                            improvementRow(imp, encounters: i.encounters)
                        } else {
                            Text("\(i.encounters) consultations reviewed")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(i.narrative)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                } else {
                    Text("Generate a summary of how you're doing and what to work on next.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Goals / focus

    @ViewBuilder private var goalsSection: some View {
        NavigationLink { GoalSettingView(location: location) } label: {
            sectionCard(title: "Focus", systemImage: "target") {
                if let label = pinnedLabel {
                    HStack(spacing: 8) {
                        Image(systemName: "pin.fill").foregroundStyle(.orange)
                        Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    }
                } else {
                    Text("Pin a skill to focus on for your next encounter.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mentor notes

    @ViewBuilder private var notesSection: some View {
        NavigationLink { MentorNotesView() } label: {
            HStack {
                Label("Chat with your mentor", systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                Spacer()
                if notesStore.unreadCount > 0 {
                    Text("\(notesStore.unreadCount)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Circle().fill(.red))
                }
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .glassHairline(16)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent sessions (History)

    @ViewBuilder private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Recent sessions", systemImage: "clock").font(.headline)
                Spacer()
                if store.visibleRecords.count > recent.count {
                    NavigationLink("See all") { HistoryView() }.font(.subheadline)
                }
            }
            if store.visibleRecords.isEmpty {
                Text("Record a consultation to see it here.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(recent) { record in
                    Button { selected = record } label: { sessionRow(record) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { deleteTarget = record } label: {
                                Label("Delete session", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }

    // MARK: - Pieces

    private var pinnedLabel: String? {
        guard let id = goals.pinnedPhaseId,
              let rubric = RubricLoader.load(for: location) else { return nil }
        return rubric.dimensions.first { $0.id == id }?.label
    }

    private func improvementRow(_ points: Double, encounters: Int) -> some View {
        let up = points >= 0
        return HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                Text("\(up ? "+" : "")\(Int(points)) pts")
            }
            .font(.subheadline.weight(.bold)).foregroundStyle(up ? .green : .red)
            Text("over \(encounters) sessions").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sessionRow(_ record: ConsultationRecord) -> some View {
        let f = record.feedback
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.locationRaw).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(record.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(f.metCount)/\(f.total)")
                .font(.headline).monospacedDigit()
                .foregroundStyle(ScoreBand.color(f.metFraction))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .glassHairline(14)
    }

    private func sectionCard<C: View>(title: String, systemImage: String,
                                      @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage).font(.headline).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .glassHairline(16)
    }
}
