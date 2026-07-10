import SwiftUI
import Charts

/// Phase-2 mentor experience, native: the Cohort tab. Everything the web
/// dashboard offers — roster with trends, trainee drill-in with per-dimension
/// charts, session cards with quotes, notes CRUD, invite-code minting, and the
/// rubric editor — against the same settled endpoints.
struct MentorHome: View {
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var store = MentorStore.shared
    @State private var showMint = false

    var body: some View {
        NavigationStack {
            Group {
                if let org = account.org, org.role == "admin" {
                    cohortList(org)
                } else {
                    ContentUnavailableView("Mentor access needed", systemImage: "person.2",
                        description: Text("Sign in with a mentor account to see your cohort."))
                }
            }
            .navigationTitle(account.org?.name ?? "Cohort")
            .ambientGradient([.teal, .blue, .indigo])
            .settingsGear()
            .toolbar {
                if let org = account.org, org.role == "admin" {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { showMint = true } label: {
                                Label("New invite code", systemImage: "key")
                            }
                            NavigationLink {
                                RubricEditorListView(org: org)
                            } label: {
                                Label("Edit rubrics", systemImage: "list.bullet.clipboard")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .sheet(isPresented: $showMint) {
                if let org = account.org { InviteMintView(org: org) }
            }
        }
    }

    private func cohortList(_ org: AccountStore.Org) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                if store.loading && store.members.isEmpty {
                    ProgressView().padding(.top, 60)
                } else if let errorMessage = store.errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red).padding()
                } else if store.members.isEmpty {
                    ContentUnavailableView("No members yet", systemImage: "person.2",
                        description: Text("Mint an invite code (⋯ menu) and share it with your trainees."))
                        .padding(.top, 40)
                }
                // You don't mentor yourself — exclude the signed-in account.
                ForEach(store.members.filter { $0.uid != account.uid }) { member in
                    NavigationLink {
                        MentorTraineeView(org: org, member: member)
                    } label: {
                        memberCard(member)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .refreshable { await store.refresh(org: org) }
        .task { await store.refresh(org: org) }
    }

    private func memberCard(_ member: MentorStore.Member) -> some View {
        let sessions = store.sessions(for: member.uid)
        let trend = store.trend(for: member.uid)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(member.label).font(.headline)
                Text(member.roleLabel +
                     (sessions.isEmpty ? " · nothing shared yet"
                                       : " · \(sessions.count) session\(sessions.count == 1 ? "" : "s")"))
                    .font(.caption).foregroundStyle(.secondary)
                if let last = sessions.first?.date {
                    Text("Last shared \(last.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if trend.count >= 2 {
                Chart(Array(trend.enumerated()), id: \.offset) { item in
                    LineMark(x: .value("Session", item.offset),
                             y: .value("Score", item.element))
                        .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: 0...1)
                .foregroundStyle(.blue)
                .frame(width: 72, height: 30)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .glassHairline(16)
    }
}

// MARK: - Trainee drill-in

struct MentorTraineeView: View {
    let org: AccountStore.Org
    let member: MentorStore.Member

    @ObservedObject private var store = MentorStore.shared
    @ObservedObject private var account = AccountStore.shared
    @State private var generalDraft = ""
    @State private var errorMessage: String?

    private var sessions: [MentorStore.Session] { store.sessions(for: member.uid) }

    var body: some View {
        List {
            let skillAreas = SkillAreas.from(sessions: sessions)
            if !skillAreas.isEmpty {
                Section("Progress by skill area") {
                    NavigationLink {
                        SkillDetailScreen(org: org, member: member,
                                          areas: skillAreas, sessions: sessions)
                    } label: {
                        SkillAreaChart(areas: skillAreas)
                            .padding(.vertical, 4)
                    }
                }
            }

            Section("Notes about \(member.label)") {
                notesList(store.generalNotes(for: member.uid))
                composer(text: $generalDraft, placeholder: "Add a note…") {
                    try await store.addNote(org: org, traineeUid: member.uid,
                                            sessionId: nil, text: generalDraft)
                    generalDraft = ""
                }
            }

            if sessions.isEmpty {
                Section {
                    Text("Nothing shared yet — sessions appear when \(member.label) shares them.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(sessions) { session in
                SessionSection(org: org, member: member, session: session)
            }

            let retracted = store.retractions(for: member.uid)
            if !retracted.isEmpty {
                Section {
                    ForEach(Array(retracted.enumerated()), id: \.offset) { _, marker in
                        Text("A session from \(marker.recordedDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—") was retracted by the trainee on \(marker.retractedDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—").")
                            .font(.caption.italic())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            }
        }
        .navigationTitle(member.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func notesList(_ notes: [NotesStore.Note]) -> some View {
        ForEach(notes) { note in
            MentorNoteRow(org: org, note: note, isMine: note.authorUid == account.uid)
        }
    }

    private func composer(text: Binding<String>, placeholder: String,
                          submit: @escaping () async throws -> Void) -> some View {
        HStack {
            TextField(placeholder, text: text, axis: .vertical)
            Button {
                Task {
                    do { try await submit(); errorMessage = nil }
                    catch { errorMessage = error.localizedDescription }
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title3)
            }
            .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

/// One shared session: header, summary, criteria with quotes, and its notes.
private struct SessionSection: View {
    let org: AccountStore.Org
    let member: MentorStore.Member
    let session: MentorStore.Session

    @ObservedObject private var store = MentorStore.shared
    @ObservedObject private var account = AccountStore.shared
    @State private var draft = ""
    @State private var expanded = false
    @State private var errorMessage: String?

    var body: some View {
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
                Button(expanded ? "Hide criteria" : "Show criteria") { expanded.toggle() }
                    .font(.caption)
            }

            if expanded {
                ForEach(session.criteria ?? [], id: \.id) { item in
                    criterionRow(item)
                }
            }

            ForEach(store.sessionNotes(for: session.id)) { note in
                MentorNoteRow(org: org, note: note, isMine: note.authorUid == account.uid)
            }
            HStack {
                TextField("Note on this session…", text: $draft, axis: .vertical)
                Button {
                    Task {
                        do {
                            try await store.addNote(org: org, traineeUid: member.uid,
                                                    sessionId: session.id, text: draft)
                            draft = ""
                            errorMessage = nil
                        } catch { errorMessage = error.localizedDescription }
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title3)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func criterionRow(_ item: SessionShare.Item) -> some View {
        let prompt = session.rubricId.flatMap { RubricLoader.load(named: $0) }?
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

/// A note row with edit/delete for the author (server enforces author-only —
/// the UI just hides the affordances from everyone else).
private struct MentorNoteRow: View {
    let org: AccountStore.Org
    let note: NotesStore.Note
    let isMine: Bool

    @ObservedObject private var store = MentorStore.shared
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(note.author).font(.caption.weight(.semibold))
                Spacer()
                Text(note.when.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if editing {
                TextField("Note", text: $draft, axis: .vertical).font(.subheadline)
                HStack {
                    Button("Save") {
                        Task {
                            try? await store.editNote(org: org, noteId: note.noteId, text: draft)
                            editing = false
                        }
                    }
                    .font(.caption)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { editing = false }.font(.caption)
                }
            } else {
                Text(note.text).font(.subheadline)
            }
        }
        .contextMenu {
            if isMine {
                Button {
                    draft = note.text
                    editing = true
                } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) {
                    Task { try? await store.deleteNote(org: org, noteId: note.noteId) }
                } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }
}

// MARK: - Invite-code minting

struct InviteMintView: View {
    let org: AccountStore.Org
    @Environment(\.dismiss) private var dismiss

    @State private var mentorRole = false
    @State private var minted: MentorStore.MintedCode?
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var copied = false
    @State private var activeInvites: [MentorStore.ActiveInvite] = []

    var body: some View {
        NavigationStack {
            Form {
                if let minted {
                    Section("Share this code") {
                        Text(minted.code)
                            .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                            .frame(maxWidth: .infinity)
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = minted.code
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy code",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        LabeledContent("Role", value: minted.roleLabel)
                        if let maxUses = minted.maxUses {
                            LabeledContent("Uses", value: "\(maxUses)")
                        }
                        if let expires = minted.expiresAt {
                            LabeledContent("Expires",
                                           value: expires.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                } else {
                    Section {
                        Toggle("Mentor code", isOn: $mentorRole)
                    } footer: {
                        Text(mentorRole
                             ? "⚠️ Whoever redeems this becomes a Mentor and can see the whole cohort. Share carefully."
                             : "Trainees who redeem this join \(org.name).")
                    }
                    Section {
                        Button {
                            mint()
                        } label: {
                            HStack {
                                Spacer()
                                if busy { ProgressView() } else { Text("Create code").bold() }
                                Spacer()
                            }
                        }
                        .disabled(busy)
                    }
                    if let errorMessage {
                        Section { Text(errorMessage).font(.caption).foregroundStyle(.red) }
                    }
                    if !activeInvites.isEmpty {
                        Section("Active codes") {
                            ForEach(activeInvites) { invite in
                                Button {
                                    UIPasteboard.general.string = invite.code
                                } label: {
                                    HStack {
                                        Text(invite.code).font(.body.monospaced().weight(.semibold))
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 1) {
                                            Text(invite.roleLabel).font(.caption)
                                            Text("\(invite.uses ?? 0)/\(invite.maxUses ?? 0) used" +
                                                 (invite.expiresDate.map { " · expires \($0.formatted(date: .numeric, time: .omitted))" } ?? ""))
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            Text("Tap a code to copy it.").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .navigationTitle("Invite code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task {
                activeInvites = (try? await MentorStore.shared.activeInvites(org: org)) ?? []
            }
        }
    }

    private func mint() {
        busy = true
        errorMessage = nil
        Task {
            do { minted = try await MentorStore.shared.mintCode(org: org, mentorRole: mentorRole) }
            catch { errorMessage = error.localizedDescription }
            busy = false
        }
    }
}


/// Wraps the shared chart-detail view with mentor navigation: selecting a
/// session point and tapping "Open session" pushes that session's full card.
struct SkillDetailScreen: View {
    let org: AccountStore.Org
    let member: MentorStore.Member
    let areas: [SkillArea]
    let sessions: [MentorStore.Session]

    @State private var openedSession: MentorStore.Session?
    @State private var showSession = false

    var body: some View {
        SkillAreasDetailView(title: member.label, areas: areas) { key in
            if let session = sessions.first(where: { $0.id == key }) {
                openedSession = session
                showSession = true
            }
        }
        .navigationDestination(isPresented: $showSession) {
            if let openedSession {
                List {
                    SessionSection(org: org, member: member, session: openedSession)
                }
                .navigationTitle(openedSession.date.map {
                    $0.formatted(date: .abbreviated, time: .shortened)
                } ?? "Session")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
