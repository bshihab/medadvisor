import Foundation

/// MC3: Tier-2 session sharing — per-criterion scores + REDACTED evidence
/// quotes, nothing else. The payload here is the ONLY shape that can travel;
/// there is deliberately no field a transcript could ride in.
/// Contract: medadvisor-cloud/PLAN.md → MC3 Interface.
enum SessionShare {
    // MARK: - Wire types (exactly the PLAN.md schema)

    struct Payload: Codable {
        let clientSessionId: String
        let recordedAt: String
        let location: String
        let rubricId: String
        let rubricVersion: String
        let summary: String?
        let criteria: [Item]
    }

    struct Item: Codable {
        let id: String
        let dimension: String
        let result: String          // met | partial | missed | na
        let evidence: String?
        let tip: String?
    }

    // MARK: - Building

    /// Server validation caps (400 invalid_body beyond these) — truncate
    /// client-side so an over-long LLM summary can't bounce a share.
    static func clip(_ s: String?, to limit: Int) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
    }

    static func wireResult(_ status: CriterionResult.Status) -> String {
        switch status {
        case .met: return "met"
        case .partial: return "partial"
        case .missed: return "missed"
        case .notApplicable: return "na"
        }
    }

    static func status(fromWire result: String) -> CriterionResult.Status {
        switch result {
        case "met": return .met
        case "partial": return .partial
        case "na": return .notApplicable
        default: return .missed
        }
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    // MARK: - Upload

    struct UploadReply: Decodable { let sessionId: String }

    @MainActor
    static func upload(_ payload: Payload) async throws {
        let _: UploadReply = try await AccountStore.shared.call(
            "v1/sessions", method: "POST", body: payload)
    }

    /// Remove the cloud copy too (owner-only server-side) — it disappears from
    /// the mentor's dashboard. Endpoint per PLAN.md (settled with the MC6 batch).
    @MainActor
    static func deleteEverywhere(_ clientSessionId: String) async throws {
        try await AccountStore.shared.callVoid("v1/sessions/\(clientSessionId)", method: "DELETE")
    }

    // MARK: - What the mentor currently has

    /// One row of "Shared with your mentor" — the SERVER's truth about what the
    /// mentor can see right now, so the trainee can always review and retract,
    /// even from a new phone or after deleting their local copy.
    struct SharedSummary: Identifiable {
        let clientSessionId: String
        let recordedAt: Date?
        let location: String?
        let met: Int
        let applicable: Int
        var id: String { clientSessionId }
    }

    /// Fetch the caller's currently-shared sessions for review/retraction.
    @MainActor
    static func fetchShared() async throws -> [SharedSummary] {
        let reply: RestoreReply = try await AccountStore.shared.call(
            "v1/me/sessions", method: "GET", body: Optional<Int>.none)
        return reply.sessions.compactMap { s in
            guard let id = s.clientSessionId else { return nil }
            let items = s.criteria ?? []
            let applicable = items.filter { $0.result != "na" }.count
            let met = items.filter { $0.result == "met" }.count
            return SharedSummary(
                clientSessionId: id,
                recordedAt: s.recordedAt.flatMap(parseDate),
                location: s.location,
                met: met,
                applicable: applicable)
        }
        .sorted { ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast) }
    }

    // MARK: - Cross-device restore

    private struct RestoredSession: Decodable {
        let clientSessionId: String?
        let recordedAt: String?
        let location: String?
        let summary: String?
        let criteria: [Item]?
        let receivedAt: String?
    }
    private struct RestoreReply: Decodable { let sessions: [RestoredSession] }

    /// Pull the caller's shared sessions and merge any this device doesn't
    /// have (fresh phone / reinstall). Silent on failure — offline is fine,
    /// and the endpoint may simply not exist yet.
    @MainActor
    static func restore() async {
        guard AccountStore.shared.isSignedIn else { return }
        guard let reply: RestoreReply = try? await AccountStore.shared.call(
            "v1/me/sessions", method: "GET", body: Optional<Int>.none) else { return }

        let records: [ConsultationRecord] = reply.sessions.compactMap { s in
            guard let id = s.clientSessionId,
                  let recordedAt = s.recordedAt, let date = parseDate(recordedAt),
                  let location = s.location, let items = s.criteria else { return nil }
            let results = items.map {
                CriterionResult(criterionId: $0.id,
                                status: status(fromWire: $0.result),
                                evidence: $0.evidence,
                                comment: $0.tip)
            }
            return ConsultationRecord(
                id: id,
                date: date,
                locationRaw: location,
                transcript: nil,               // transcripts never sync, by design
                turns: nil,
                feedback: ConsultationFeedback(perCriterion: results, summary: s.summary),
                sharedAt: s.receivedAt.flatMap(parseDate),
                ownerUid: AccountStore.shared.uid)
        }
        FeedbackStore.shared.mergeRestored(records)
    }
}
