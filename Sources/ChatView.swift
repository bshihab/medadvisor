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
    let anchorKey: String?      // session key for navigation (server id / record id)
    let anchorCriterionId: String?  // criterion to focus within the session, if any
    let rootNoteId: String      // thread this entry belongs to
    let isRoot: Bool
}

enum ChatFlattener {
    static func entries(notes: [NotesStore.Note],
                        myUid: String?,
                        anchorInfo: (NotesStore.Note) -> (label: String, key: String?, criterionId: String?)?) -> [ChatEntry] {
        let roots = notes.sorted { ($0.when ?? .distantPast) < ($1.when ?? .distantPast) }
        var out: [ChatEntry] = []
        for note in roots {
            let info = anchorInfo(note)
            out.append(ChatEntry(
                id: "n-\(note.noteId)",
                author: note.author,
                isMine: note.authorUid == myUid,
                isMentor: true,                    // roots are mentor-authored per contract
                text: note.text,
                when: note.when,
                anchor: info?.label,
                anchorKey: info?.key,
                anchorCriterionId: info?.criterionId,
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
                    anchorKey: nil,
                    anchorCriterionId: nil,
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
    /// Tapping a message's anchor chip navigates to that session (+ criterion).
    var onOpenAnchor: ((String, String?) -> Void)? = nil

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
                        ChatBubble(entry: entry, onOpenAnchor: onOpenAnchor)
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
    var onOpenAnchor: ((String, String?) -> Void)? = nil

    var body: some View {
        VStack(alignment: entry.isMine ? .trailing : .leading, spacing: 3) {
            HStack {
                if entry.isMine { Spacer(minLength: 48) }
                VStack(alignment: .leading, spacing: 5) {
                    if let anchor = entry.anchor {
                        Button {
                            if let key = entry.anchorKey { onOpenAnchor?(key, entry.anchorCriterionId) }
                        } label: {
                            Label(anchor, systemImage: "paperclip")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(entry.isMine ? .white.opacity(0.85) : Color.blue)
                                .lineLimit(2)
                                .underline(entry.anchorKey != nil && onOpenAnchor != nil)
                        }
                        .buttonStyle(.plain)
                        .disabled(entry.anchorKey == nil || onOpenAnchor == nil)
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

    @State private var openedRecord: ConsultationRecord?
    @State private var focusCriterionId: String?
    @State private var newMessage = ""
    @State private var sending = false
    @State private var sendError: String?

    var body: some View {
        VStack(spacing: 0) {
            ChatThreadList(
                entries: ChatFlattener.entries(notes: notesStore.notes,
                                               myUid: account.uid,
                                               anchorInfo: anchorInfo),
                emptyText: "No messages yet.\nStart a conversation with your mentor below — ask about a session you've shared, or anything else — and reply to whatever they send.",
                onReply: { noteId, text in
                    guard let orgId = account.org?.orgId else { throw AccountStore.APIError.notSignedIn }
                    try await notesStore.reply(orgId: orgId, noteId: noteId, text: text)
                },
                onOpenAnchor: { recordId, criterionId in
                    openedRecord = feedback.records.first { $0.id == recordId }
                    focusCriterionId = criterionId
                })
            composer
        }
        .navigationTitle("Mentor chat")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            notesStore.markAllSeen()
            await notesStore.refresh()
        }
        .sheet(item: $openedRecord) { record in
            if let location = record.location, let rubric = RubricLoader.load(for: location) {
                FeedbackView(feedback: record.feedback, rubric: rubric,
                             transcript: record.transcript, turns: record.turns,
                             record: record, focusCriterionId: focusCriterionId)
            }
        }
    }

    /// Bottom composer so the trainee can START a thread, not just reply.
    private var composer: some View {
        VStack(spacing: 4) {
            if let sendError {
                Text(sendError).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message your mentor…", text: $newMessage, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                Button {
                    let text = newMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    sending = true
                    sendError = nil
                    Task {
                        do {
                            try await notesStore.startThread(text: text)
                            newMessage = ""
                            notesStore.markAllSeen()
                        } catch {
                            sendError = error.localizedDescription
                        }
                        sending = false
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(sending || newMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Server sessionId is "{uid}__{clientSessionId}" — match local records by
    /// suffix, then resolve the criterion prompt from that record's rubric.
    private func anchorInfo(_ note: NotesStore.Note) -> (label: String, key: String?, criterionId: String?)? {
        guard let sessionId = note.sessionId else { return nil }
        let record = feedback.records.first { sessionId.hasSuffix($0.id) }
        var label = record.map { "Session \($0.date.formatted(date: .abbreviated, time: .omitted))" }
            ?? "A shared session"
        if let criterionId = note.criterionId {
            let prompt = record?.location
                .flatMap { RubricLoader.load(for: $0) }?
                .criteria.first { $0.id == criterionId }?.prompt
            label += " · " + (prompt ?? "a criterion since removed from the rubric")
        }
        return (label, record?.id, note.criterionId)
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
    @State private var openedSession: MentorStore.Session?
    @State private var openedCriterionId: String?
    @State private var showOpenedSession = false

    var body: some View {
        VStack(spacing: 0) {
            ChatThreadList(
                entries: ChatFlattener.entries(
                    notes: store.notes.filter { $0.traineeUid == member.uid },
                    myUid: account.uid,
                    anchorInfo: anchorInfo),
                emptyText: "No messages with \(member.label) yet — write below. Attach a message to a session or criterion via the 💬 buttons on their sessions.",
                onReply: { noteId, text in
                    try await store.addReply(org: org, noteId: noteId, text: text)
                },
                onOpenAnchor: { sessionId, criterionId in
                    if let session = store.sessions(for: member.uid).first(where: { $0.id == sessionId }) {
                        openedSession = session
                        openedCriterionId = criterionId
                        showOpenedSession = true
                    }
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
        .navigationDestination(isPresented: $showOpenedSession) {
            if let openedSession {
                SessionDetailScreen(org: org, member: member, session: openedSession,
                                    focusCriterionId: openedCriterionId)
            }
        }
        .task {
            // Ensure the thread is loaded even when opened directly (from a
            // session/criterion chip) rather than via the cohort refresh —
            // this was the "blank screen until you open the main chat" bug.
            if store.notes.isEmpty { await store.refresh(org: org) }
        }
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

    private func anchorInfo(_ note: NotesStore.Note) -> (label: String, key: String?, criterionId: String?)? {
        guard let sessionId = note.sessionId else { return nil }
        return (label(sessionId: sessionId, criterionId: note.criterionId), sessionId, note.criterionId)
    }

    private func label(sessionId: String, criterionId: String?) -> String {
        let session = store.sessions(for: member.uid).first { $0.id == sessionId }
        var label = session?.date.map { "Session \($0.formatted(date: .abbreviated, time: .omitted))" }
            ?? "A shared session"
        if let criterionId {
            let prompt = session?.rubricId
                .flatMap { RubricLoader.load(named: $0) }?
                .criteria.first { $0.id == criterionId }?.prompt
            label += " · " + (prompt ?? "a criterion since removed from the rubric")
        }
        return label
    }
}
