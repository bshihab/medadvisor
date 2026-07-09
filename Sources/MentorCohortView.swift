import SwiftUI

/// Phase-1 native mentor view (read-only): cohort roster → trainee → their
/// shared sessions, rendered from the same org endpoints the web dashboard
/// uses. Appears only for accounts whose org role is admin (shown as
/// "Mentor"). The website remains the full tool (rubric editor, notes).
struct MentorCohortView: View {
    let org: AccountStore.Org

    struct Member: Decodable, Identifiable {
        let uid: String
        let email: String?
        let displayName: String?
        let role: String
        var id: String { uid }
        var label: String { displayName ?? email ?? uid }
        var roleLabel: String { role == "admin" ? "Mentor" : "Trainee" }
    }
    private struct MembersReply: Decodable { let members: [Member] }

    @State private var members: [Member] = []
    @State private var errorMessage: String?
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            } else if members.isEmpty {
                ContentUnavailableView("No members yet", systemImage: "person.2",
                    description: Text("Trainees appear here once they join with an invite code."))
            }
            ForEach(members) { member in
                NavigationLink {
                    MentorTraineeView(org: org, member: member)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.label)
                        Text(member.roleLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(org.name)
        .task {
            do {
                let reply: MembersReply = try await AccountStore.shared.call(
                    "v1/orgs/\(org.orgId)/members", method: "GET", body: Optional<Int>.none)
                members = reply.members.sorted { $0.label < $1.label }
            } catch {
                errorMessage = error.localizedDescription
            }
            loading = false
        }
    }
}

/// One trainee's shared sessions (scores + approved quotes — all a mentor
/// can ever see).
struct MentorTraineeView: View {
    let org: AccountStore.Org
    let member: MentorCohortView.Member

    struct Session: Decodable, Identifiable {
        let sessionId: String?
        let clientSessionId: String?
        let recordedAt: String?
        let location: String?
        let rubricId: String?
        let summary: String?
        let criteria: [SessionShare.Item]?
        var id: String { sessionId ?? clientSessionId ?? UUID().uuidString }

        var date: Date? { recordedAt.flatMap(SessionShare.parseDate) }
        var metLine: String {
            let items = criteria ?? []
            let applicable = items.filter { $0.result != "na" }
            let met = items.filter { $0.result == "met" }
            return "\(met.count) of \(applicable.count) met"
        }
    }
    private struct SessionsReply: Decodable { let sessions: [Session] }

    @State private var sessions: [Session] = []
    @State private var errorMessage: String?
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            } else if sessions.isEmpty {
                ContentUnavailableView("Nothing shared yet", systemImage: "tray",
                    description: Text("Sessions appear when \(member.label) shares them."))
            }
            ForEach(sessions) { session in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(session.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(session.metLine).font(.caption).foregroundStyle(.secondary)
                        }
                        if let location = session.location {
                            Text(location).font(.caption).foregroundStyle(.secondary)
                        }
                        if let summary = session.summary, !summary.isEmpty {
                            Text(summary).font(.footnote)
                        }
                    }
                    ForEach(session.criteria ?? [], id: \.id) { item in
                        criterionRow(item, rubricId: session.rubricId)
                    }
                }
            }
        }
        .navigationTitle(member.label)
        .task {
            do {
                let reply: SessionsReply = try await AccountStore.shared.call(
                    "v1/orgs/\(org.orgId)/sessions?uid=\(member.uid)", method: "GET",
                    body: Optional<Int>.none)
                sessions = reply.sessions.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            } catch {
                errorMessage = error.localizedDescription
            }
            loading = false
        }
    }

    @ViewBuilder
    private func criterionRow(_ item: SessionShare.Item, rubricId: String?) -> some View {
        let prompt = rubricId.flatMap { RubricLoader.load(named: $0) }?
            .criteria.first { $0.id == item.id }?.prompt ?? item.id
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                statusIcon(item.result)
                Text(prompt).font(.caption)
            }
            if let quote = item.evidence, !quote.isEmpty {
                Text("“\(quote)”").font(.caption.italic()).foregroundStyle(.secondary)
                    .padding(.leading, 22)
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ result: String) -> some View {
        switch result {
        case "met":     Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "partial": Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case "na":      Image(systemName: "minus.circle").foregroundStyle(.gray)
        default:        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}
