import SwiftUI

/// MC6 client: mentor notes, pull-based (no push until the APNs milestone).
/// The server stores no read receipts — the unread badge is driven by a
/// locally persisted last-seen timestamp, per the settled PLAN.md contract.
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()
    private init() {}

    struct Reply: Decodable, Identifiable {
        let replyId: String
        let parentNoteId: String
        let authorUid: String?
        let authorEmail: String?
        let authorDisplayName: String?
        let authorRole: String?          // "admin" | "trainee"
        let text: String
        let createdAt: String
        let updatedAt: String?

        var id: String { replyId }
        var author: String { authorDisplayName ?? authorEmail ?? "—" }
        var when: Date? { SessionShare.parseDate(createdAt) }
        var isMentor: Bool { authorRole == "admin" }
    }

    struct Note: Decodable, Identifiable {
        let noteId: String
        let sessionId: String?
        let criterionId: String?
        let traineeUid: String
        let authorUid: String?
        let authorEmail: String?
        let authorDisplayName: String?
        let text: String
        let createdAt: String
        let updatedAt: String
        var replies: [Reply]?

        var id: String { noteId }
        var author: String { authorDisplayName ?? authorEmail ?? "Your mentor" }
        var when: Date? { SessionShare.parseDate(createdAt) }
        var lastActivity: Date? {
            (replies ?? []).compactMap(\.when).max() ?? when
        }
    }
    private struct Reply: Decodable { let notes: [Note] }

    @Published private(set) var notes: [Note] = []

    private static let lastSeenKey = "mentorNotesLastSeen"

    var lastSeen: Date {
        Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Self.lastSeenKey))
    }

    var unreadCount: Int {
        let seen = lastSeen
        let newRoots = notes.filter { ($0.when ?? .distantPast) > seen }.count
        let newReplies = notes.flatMap { $0.replies ?? [] }
            .filter { !( $0.isMentor == false ) }   // only mentor replies badge the trainee
            .filter { ($0.when ?? .distantPast) > seen }.count
        return newRoots + newReplies
    }

    /// Pull the trainee's notes (silent on failure — offline fine).
    func refresh() async {
        guard AccountStore.shared.isSignedIn else { return }
        guard let reply: Reply = try? await AccountStore.shared.call(
            "v1/me/notes", method: "GET", body: Optional<Int>.none) else { return }
        notes = reply.notes
    }

    /// Trainee replies to a root note (contract: root's trainee only).
    func reply(orgId: String, noteId: String, text: String) async throws {
        struct Body: Encodable { let text: String }
        let reply: Reply = try await AccountStore.shared.call(
            "v1/orgs/\(orgId)/notes/\(noteId)/replies", method: "POST", body: Body(text: text))
        if let idx = notes.firstIndex(where: { $0.noteId == noteId }) {
            notes[idx].replies = (notes[idx].replies ?? []) + [reply]
        }
    }

    func markAllSeen() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastSeenKey)
        objectWillChange.send()
    }
}

/// Kept as the navigation target name (Progress card + push tap) — the
/// content is now the unified chat.
struct MentorNotesView: View {
    var body: some View { TraineeChatScreen() }
}
