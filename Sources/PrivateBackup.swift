import Foundation

/// MC9 client: automatic private cloud backup of the trainee's OWN session
/// results — scores + redacted quotes + summary, NEVER transcript or audio.
/// Only the owner can read it (users/{uid}/backupSessions); invisible to any
/// org/mentor. Contract: medadvisor-cloud/PLAN.md → MC9 · design in
/// medadvisor-cloud/docs/private-backup-design.md.
///
/// Decisions (settled): D1 no transcript · D2 on by default · D4 logout never
/// deletes, uploads need auth so a backlog drains on next sign-in · D5 delete
/// removes device + private backup (mentor copy only via "Delete everywhere").
enum PrivateBackup {
    private static let enabledKey = "privateBackupEnabled"

    /// On by default (D2). Turning off stops future uploads; existing backups
    /// remain until the session is deleted.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    // MARK: - Build the (redacted, no-transcript) payload

    private static func payload(for record: ConsultationRecord) -> SessionShare.Payload? {
        guard let location = record.location,
              let rubric = RubricLoader.load(for: location) else { return nil }
        let items = record.feedback.perCriterion.map { r -> SessionShare.Item in
            let dimension = rubric.criteria.first { $0.id == r.criterionId }?.dimension ?? ""
            // Automated redaction pass (no human gate — only the owner sees it).
            let evidence = r.evidence.flatMap { SessionShare.clip(PHIRedactor.redact($0), to: 500) }
            let tip = r.comment.flatMap { SessionShare.clip(PHIRedactor.redact($0), to: 500) }
            return SessionShare.Item(id: r.criterionId, dimension: dimension,
                                     result: SessionShare.wireResult(r.status),
                                     evidence: evidence, tip: tip)
        }
        return SessionShare.Payload(
            clientSessionId: record.id,
            recordedAt: SessionShare.iso.string(from: record.date),
            location: record.locationRaw,
            rubricId: rubric.id,
            rubricVersion: rubric.version,
            summary: record.feedback.summary.flatMap { SessionShare.clip(PHIRedactor.redact($0), to: 2000) },
            criteria: items)
    }

    private struct BackupReply: Decodable { let clientSessionId: String? }

    // MARK: - Drive the queue

    /// Upload every not-yet-backed-up record for the signed-in user. Silent on
    /// failure (offline / endpoint not live yet). Call after an analysis, on
    /// sign-in, and on foreground.
    @MainActor
    static func syncPending() async {
        guard enabled, AccountStore.shared.isSignedIn else { return }
        for record in FeedbackStore.shared.pendingBackup() {
            guard let payload = payload(for: record) else { continue }
            do {
                let _: BackupReply = try await AccountStore.shared.call(
                    "v1/me/backup/sessions/\(record.id)", method: "PUT", body: payload)
                FeedbackStore.shared.markBackedUp(record.id)
            } catch {
                // Stop on first failure — likely offline or endpoint absent;
                // the rest retry next time. No noise.
                return
            }
        }
    }

    /// Remove one session's private backup (D5 — part of a regular delete).
    @MainActor
    static func deleteBackup(_ clientSessionId: String) async {
        guard AccountStore.shared.isSignedIn else { return }
        try? await AccountStore.shared.callVoid(
            "v1/me/backup/sessions/\(clientSessionId)", method: "DELETE")
    }

    // MARK: - Cross-device restore

    private struct Restored: Decodable {
        let clientSessionId: String?
        let recordedAt: String?
        let location: String?
        let summary: String?
        let criteria: [SessionShare.Item]?
        let backedUpAt: String?
    }
    private struct RestoreReply: Decodable { let sessions: [Restored] }

    /// Pull the owner's private backups and merge any this device lacks (fresh
    /// phone / reinstall). No transcript by design.
    @MainActor
    static func restore() async {
        guard enabled, AccountStore.shared.isSignedIn else { return }
        guard let reply: RestoreReply = try? await AccountStore.shared.call(
            "v1/me/backup/sessions", method: "GET", body: Optional<Int>.none) else { return }
        let records: [ConsultationRecord] = reply.sessions.compactMap { s in
            guard let id = s.clientSessionId,
                  let recordedAt = s.recordedAt, let date = SessionShare.parseDate(recordedAt),
                  let location = s.location, let items = s.criteria else { return nil }
            let results = items.map {
                CriterionResult(criterionId: $0.id,
                                status: SessionShare.status(fromWire: $0.result),
                                evidence: $0.evidence, comment: $0.tip)
            }
            return ConsultationRecord(
                id: id, date: date, locationRaw: location,
                transcript: nil, turns: nil,
                feedback: ConsultationFeedback(perCriterion: results, summary: s.summary),
                sharedAt: nil,
                ownerUid: AccountStore.shared.uid,
                backedUpAt: s.backedUpAt.flatMap(SessionShare.parseDate) ?? Date())
        }
        FeedbackStore.shared.mergeRestored(records)
    }
}
