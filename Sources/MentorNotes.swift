import SwiftUI

/// MC6 client: mentor notes, pull-based (no push until the APNs milestone).
/// The server stores no read receipts — the unread badge is driven by a
/// locally persisted last-seen timestamp, per the settled PLAN.md contract.
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()
    private init() {}

    struct Note: Decodable, Identifiable {
        let noteId: String
        let sessionId: String?
        let traineeUid: String
        let authorEmail: String?
        let authorDisplayName: String?
        let text: String
        let createdAt: String
        let updatedAt: String

        var id: String { noteId }
        var author: String { authorDisplayName ?? authorEmail ?? "Your mentor" }
        var when: Date? { SessionShare.parseDate(updatedAt) ?? SessionShare.parseDate(createdAt) }
    }
    private struct Reply: Decodable { let notes: [Note] }

    @Published private(set) var notes: [Note] = []

    private static let lastSeenKey = "mentorNotesLastSeen"

    var lastSeen: Date {
        Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Self.lastSeenKey))
    }

    var unreadCount: Int {
        notes.filter { ($0.when ?? .distantPast) > lastSeen }.count
    }

    /// Pull the trainee's notes (silent on failure — offline fine).
    func refresh() async {
        guard AccountStore.shared.isSignedIn else { return }
        guard let reply: Reply = try? await AccountStore.shared.call(
            "v1/me/notes", method: "GET", body: Optional<Int>.none) else { return }
        notes = reply.notes
    }

    func markAllSeen() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastSeenKey)
        objectWillChange.send()
    }
}

/// The trainee's notes list. Unread state is captured at open so the dots
/// don't vanish mid-read; everything is marked seen when the view appears.
struct MentorNotesView: View {
    @ObservedObject private var store = NotesStore.shared
    @State private var unreadAtOpen: Set<String> = []

    var body: some View {
        List {
            if store.notes.isEmpty {
                ContentUnavailableView("No notes yet", systemImage: "note.text",
                    description: Text("Notes from your mentor show up here."))
            }
            ForEach(store.notes) { note in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if unreadAtOpen.contains(note.id) {
                            Circle().fill(.blue).frame(width: 8, height: 8)
                        }
                        Text(note.author).font(.caption.weight(.semibold))
                        Spacer()
                        Text(note.when.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(note.text).font(.subheadline)
                    if note.sessionId != nil {
                        Label("About one of your sessions", systemImage: "waveform")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Mentor notes")
        .task {
            let seen = store.lastSeen
            unreadAtOpen = Set(store.notes.filter { ($0.when ?? .distantPast) > seen }.map(\.id))
            store.markAllSeen()
            await store.refresh()
        }
    }
}
