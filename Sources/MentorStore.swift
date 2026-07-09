import Foundation
import UIKit

/// Phase-2 mentor data: roster + every member's shared sessions + org notes,
/// fetched against the same settled endpoints the web dashboard uses.
/// Per-member sessions are fetched with the ?uid= filter (the contract's
/// item shape carries no uid, so org-wide grouping happens by query).
@MainActor
final class MentorStore: ObservableObject {
    static let shared = MentorStore()
    private init() {}

    // MARK: - Wire types

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

        /// Web-dashboard scoring convention (display only): met=1, partial=0.5,
        /// missed=0, na excluded; dimension = mean of its criteria; overall =
        /// mean of dimension scores.
        var dimensionScores: [String: Double] {
            var buckets: [String: [Double]] = [:]
            for item in criteria ?? [] where item.result != "na" {
                let value: Double = item.result == "met" ? 1 : (item.result == "partial" ? 0.5 : 0)
                buckets[item.dimension, default: []].append(value)
            }
            return buckets.mapValues { $0.reduce(0, +) / Double($0.count) }
        }
        var overallScore: Double? {
            let scores = dimensionScores.values
            guard !scores.isEmpty else { return nil }
            return scores.reduce(0, +) / Double(scores.count)
        }
        var metLine: String {
            let items = criteria ?? []
            let applicable = items.filter { $0.result != "na" }
            let met = items.filter { $0.result == "met" }
            return "\(met.count) of \(applicable.count) met"
        }
    }
    private struct SessionsReply: Decodable { let sessions: [Session] }

    private struct NotesReply: Decodable { let notes: [NotesStore.Note] }
    private struct MintReply: Decodable {
        let code: String
        let role: String
        let maxUses: Int?
        let expiresAt: String?
    }

    // MARK: - State

    @Published private(set) var members: [Member] = []
    @Published private(set) var sessionsByUid: [String: [Session]] = [:]
    @Published private(set) var notes: [NotesStore.Note] = []
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?

    func sessions(for uid: String) -> [Session] { sessionsByUid[uid] ?? [] }
    func generalNotes(for uid: String) -> [NotesStore.Note] {
        notes.filter { $0.traineeUid == uid && $0.sessionId == nil }
    }
    func sessionNotes(for sessionId: String) -> [NotesStore.Note] {
        notes.filter { $0.sessionId == sessionId }
    }
    /// Chronological overall scores for the sparkline.
    func trend(for uid: String) -> [Double] {
        sessions(for: uid)
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            .compactMap(\.overallScore)
    }

    // MARK: - Fetch

    func refresh(org: AccountStore.Org) async {
        loading = true
        errorMessage = nil
        do {
            let reply: MembersReply = try await AccountStore.shared.call(
                "v1/orgs/\(org.orgId)/members", method: "GET", body: Optional<Int>.none)
            members = reply.members.sorted { $0.label < $1.label }

            var byUid: [String: [Session]] = [:]
            for member in members {   // cohorts are small; sequential is fine
                let sessions: SessionsReply = try await AccountStore.shared.call(
                    "v1/orgs/\(org.orgId)/sessions?uid=\(member.uid)", method: "GET",
                    body: Optional<Int>.none)
                byUid[member.uid] = sessions.sessions
                    .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            }
            sessionsByUid = byUid

            let notesReply: NotesReply = try await AccountStore.shared.call(
                "v1/orgs/\(org.orgId)/notes?limit=500", method: "GET", body: Optional<Int>.none)
            notes = notesReply.notes
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    // MARK: - Notes CRUD (author-only rules enforced server-side)

    func addNote(org: AccountStore.Org, traineeUid: String, sessionId: String?, text: String) async throws {
        struct Body: Encodable { let traineeUid: String; let sessionId: String?; let text: String }
        let note: NotesStore.Note = try await AccountStore.shared.call(
            "v1/orgs/\(org.orgId)/notes", method: "POST",
            body: Body(traineeUid: traineeUid, sessionId: sessionId, text: text))
        notes.insert(note, at: 0)
    }

    func editNote(org: AccountStore.Org, noteId: String, text: String) async throws {
        struct Body: Encodable { let text: String }
        let updated: NotesStore.Note = try await AccountStore.shared.call(
            "v1/orgs/\(org.orgId)/notes/\(noteId)", method: "PATCH", body: Body(text: text))
        if let idx = notes.firstIndex(where: { $0.noteId == noteId }) { notes[idx] = updated }
    }

    func deleteNote(org: AccountStore.Org, noteId: String) async throws {
        try await AccountStore.shared.callVoid("v1/orgs/\(org.orgId)/notes/\(noteId)", method: "DELETE")
        notes.removeAll { $0.noteId == noteId }
    }

    // MARK: - Invite codes

    struct MintedCode {
        let code: String
        let roleLabel: String
        let maxUses: Int?
        let expiresAt: Date?
    }

    func mintCode(org: AccountStore.Org, mentorRole: Bool) async throws -> MintedCode {
        struct Body: Encodable { let role: String }
        let reply: MintReply = try await AccountStore.shared.call(
            "v1/orgs/\(org.orgId)/invites", method: "POST",
            body: Body(role: mentorRole ? "admin" : "trainee"))
        return MintedCode(code: reply.code,
                          roleLabel: mentorRole ? "Mentor" : "Trainee",
                          maxUses: reply.maxUses,
                          expiresAt: reply.expiresAt.flatMap(SessionShare.parseDate))
    }
}
