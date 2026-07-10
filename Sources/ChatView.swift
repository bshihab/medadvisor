import SwiftUI

/// The unified mentor↔trainee chat, rendered over the MC8 notes+replies
/// contract: every root note is a thread starter (optionally anchored to a
/// session or a specific criterion — shown as a chip), replies flow beneath
/// it, and the whole thing reads as one chronological conversation. Trainees
/// reply to threads (the contract's rule: mentors start threads — an additive
/// change later can lift that).
// MARK: - Message model (flattened for rendering)

struct ChatEntry: Identifiable {
    let id: String
    let author: String
    let isMine: Bool
    let isMentor: Bool
    let text: String
    let when: Date?
    let anchor: String?         // resolved human label, e.g. "Session Jul 9 · Elicits concerns"
    let rootNoteId: String      // thread this entry belongs to
    let isRoot: Bool
}

enum ChatFlattener {
    static func entries(notes: [NotesStore.Note],
                        myUid: String?,
                        anchorLabel: (NotesStore.Note) -> String?) -> [ChatEntry] {
        let roots = notes.sorted { ($0.when ?? .distantPast) < ($1.when ?? .distantPast) }
        var out: [ChatEntry] = []
        for note in roots {
            out.append(ChatEntry(
                id: "n-\(note.noteId)",
                author: note.author,
                isMine: note.authorUid == myUid,
                isMentor: true,                    // roots are mentor-authored per contract
                text: note.text,
                when: note.when,
                anchor: anchorLabel(note),
                rootNoteId: note.noteId,
                isRoot: true))
            for reply in (note.replies ?? []).sorted(by: { ($0.when ?? .distantPast) < ($1.when ?? .distantPast) }) {
                out.append(ChatEntry(
                    id: "r-\(reply.replyId)",
                    author: reply.author,
                    isMine: reply.authorUid == myUid,
                    isMentor: reply.isMentor,
                    text: reply.text,
                    when: reply.when,
                    anchor: nil,
                    rootNoteId: note.noteId,
                    isRoot: false))
            }
        }
        return out
    }
}

// MARK: - Shared chat renderer

struct ChatThreadList: View {
    let entries: [ChatEntry]
    let emptyText: String
    /// Called with (rootNoteId, text) when a reply is sent from a thread.
    let onReply: (String, String) async throws -> Void

    @State private var replyingTo: String?
    @State private var replyDraft = ""
    @State private var errorMessage: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if entries.isEmpty {
                        Text(emptyText)
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 60)
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        // New thread → breathing room + reply affordance on
                        // the previous thread's tail.
                        if entry.isRoot && index > 0 {
                            replyControl(rootId: entries[index - 1].rootNoteId)
                            Divider().padding(.vertical, 8)
                        }
                        ChatBubble(entry: entry)
                            .id(entry.id)
                    }
                    if let last = entries.last {
                        replyControl(rootId: last.rootNoteId)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .onAppear {
                if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: entries.count) { _, _ in
                if let last = entries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func replyControl(rootId: String) -> some View {
        if replyingTo == rootId {
            HStack {
                TextField("Reply…", text: $replyDraft, axis: .vertical)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                Button {
                    let text = replyDraft
                    Task {
                        do {
                            try await onReply(rootId, text)
                            replyDraft = ""
                            replyingTo = nil
                            errorMessage = nil
                        } catch { errorMessage = error.localizedDescription }
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 2)
        } else {
            HStack {
                Button("Reply") { replyingTo = rootId; replyDraft = "" }
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            .padding(.leading, 6)
        }
    }
}

struct ChatBubble: View {
    let entry: ChatEntry

    var body: some View {
        VStack(alignment: entry.isMine ? .trailing : .leading, spacing: 3) {
            HStack {
                if entry.isMine { Spacer(minLength: 48) }
                VStack(alignment: .leading, spacing: 5) {
                    if let anchor = entry.anchor {
                        Label(anchor, systemImage: "paperclip")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(entry.isMine ? .white.opacity(0.85) : Color.blue)
                            .lineLimit(2)
                    }
                    Text(entry.text)
                        .font(.subheadline)
                        .foregroundStyle(entry.isMine ? .white : .primary)
                }
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(
                    entry.isMine ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: 17))
                .glassHairline(17)
                if !entry.isMine { Spacer(minLength: 48) }
            }
            Text("\(entry.author) · \(entry.when.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, alignment: entry.isMine ? .trailing : .leading)
    }
}

// MARK: - Trainee side

struct TraineeChatScreen: View {
    @ObservedObject private var notesStore = NotesStore.shared
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var feedback = FeedbackStore.shared

    var body: some View {
        ChatThreadList(
            entries: ChatFlattener.entries(notes: notesStore.notes,
                                           myUid: account.uid,
                                           anchorLabel: anchorLabel),
            emptyText: "No messages yet.\nYour mentor starts conversations here — often about a session you've shared — and you can reply to any of them.",
            onReply: { noteId, text in
                guard let orgId = account.org?.orgId else { throw AccountStore.APIError.notSignedIn }
                try await notesStore.reply(orgId: orgId, noteId: noteId, text: text)
            })
        .navigationTitle("Mentor chat")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            notesStore.markAllSeen()
            await notesStore.refresh()
        }
    }

    /// Server sessionId is "{uid}__{clientSessionId}" — match local records by
    /// suffix, then resolve the criterion prompt from that record's rubric.
    private func anchorLabel(_ note: NotesStore.Note) -> String? {
        guard let sessionId = note.sessionId else { return nil }
        let record = feedback.records.first { sessionId.hasSuffix($0.id) }
        var label = record.map { "Session \($0.date.formatted(date: .abbreviated, time: .omitted))" }
            ?? "A shared session"
        if let criterionId = note.criterionId {
            let prompt = record?.location
                .flatMap { RubricLoader.load(for: $0) }?
                .criteria.first { $0.id == criterionId }?.prompt
            label += " · \(prompt ?? criterionId)"
        }
        return label
    }
}

// MARK: - Mentor side

struct MentorChatScreen: View {
    let org: AccountStore.Org
    let member: MentorStore.Member
    /// Prefilled anchor when opened from a session/criterion 💬.
    var prefillSessionId: String? = nil
    var prefillCriterionId: String? = nil

    @ObservedObject private var store = MentorStore.shared
    @ObservedObject private var account = AccountStore.shared
    @State private var draft = ""
    @State private var anchorSessionId: String?
    @State private var anchorCriterionId: String?
    @State private var anchorArmed = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ChatThreadList(
                entries: ChatFlattener.entries(
                    notes: store.notes.filter { $0.traineeUid == member.uid },
                    myUid: account.uid,
                    anchorLabel: anchorLabel),
                emptyText: "No messages with \(member.label) yet — write below. Attach a message to a session or criterion via the 💬 buttons on their sessions.",
                onReply: { noteId, text in
                    try await store.addReply(org: org, noteId: noteId, text: text)
                })

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let label = currentAnchorLabel {
                    HStack(spacing: 6) {
                        Label(label, systemImage: "paperclip")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.blue)
                            .lineLimit(1)
                        Button {
                            anchorSessionId = nil
                            anchorCriterionId = nil
                        } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("Message \(member.label)…", text: $draft, axis: .vertical)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(10)
        }
        .navigationTitle(member.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !anchorArmed {
                anchorSessionId = prefillSessionId
                anchorCriterionId = prefillCriterionId
                anchorArmed = true
            }
        }
    }

    private func send() {
        let text = draft
        Task {
            do {
                try await store.addNote(org: org, traineeUid: member.uid,
                                        sessionId: anchorSessionId,
                                        criterionId: anchorCriterionId,
                                        text: text)
                draft = ""
                anchorSessionId = nil
                anchorCriterionId = nil
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private var currentAnchorLabel: String? {
        guard let sessionId = anchorSessionId else { return nil }
        return label(sessionId: sessionId, criterionId: anchorCriterionId)
    }

    private func anchorLabel(_ note: NotesStore.Note) -> String? {
        guard let sessionId = note.sessionId else { return nil }
        return label(sessionId: sessionId, criterionId: note.criterionId)
    }

    private func label(sessionId: String, criterionId: String?) -> String {
        let session = store.sessions(for: member.uid).first { $0.id == sessionId }
        var label = session?.date.map { "Session \($0.formatted(date: .abbreviated, time: .omitted))" }
            ?? "A shared session"
        if let criterionId {
            let prompt = session?.rubricId
                .flatMap { RubricLoader.load(named: $0) }?
                .criteria.first { $0.id == criterionId }?.prompt
            label += " · \(prompt ?? criterionId)"
        }
        return label
    }
}
