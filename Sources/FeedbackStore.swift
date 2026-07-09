import Foundation

/// One saved consultation's feedback. We persist the structured feedback +
/// location + date — never the audio or transcript (those are deleted after analysis).
struct ConsultationRecord: Codable, Identifiable, Equatable {
    let id: String
    let date: Date
    let locationRaw: String
    /// Redacted transcript (optional for older records).
    var transcript: String?
    /// Redacted, speaker-labeled turns for the chat view (nil/empty if 1 speaker).
    var turns: [TranscriptTurn]?
    let feedback: ConsultationFeedback
    /// When this session was shared with the mentor (nil = never shared).
    var sharedAt: Date? = nil
    /// Account that recorded it (nil = recorded signed-out / pre-accounts).
    var ownerUid: String? = nil

    var location: AppLocation? { AppLocation(rawValue: locationRaw) }
}

/// Persists feedback records to disk, encrypted at rest via iOS Data Protection
/// (`.completeFileProtection` — files are unreadable while the device is locked
/// and tied to the device passcode). No keys to manage.
@MainActor
final class FeedbackStore: ObservableObject {
    static let shared = FeedbackStore()

    @Published private(set) var records: [ConsultationRecord] = []
    /// Current account (set by AccountStore on auth changes) — scopes visibility.
    @Published var currentUid: String?

    /// What the UI shows: your own records plus anonymous/legacy ones. Another
    /// account's sessions never leak across sign-ins on a shared device.
    var visibleRecords: [ConsultationRecord] {
        records.filter { $0.ownerUid == nil || $0.ownerUid == currentUid }
    }

    private let dir: URL

    init() {
        dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("feedback", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    func add(_ record: ConsultationRecord) {
        records.insert(record, at: 0)
        save(record)
    }

    func delete(_ record: ConsultationRecord) {
        // Shared sessions get a tombstone so cloud restore never resurrects a
        // session the user deleted on this device.
        if record.sharedAt != nil { Self.addTombstone(record.id) }
        records.removeAll { $0.id == record.id }
        try? FileManager.default.removeItem(at: fileURL(record.id))
    }

    // MARK: - Tombstones (per-device)

    private static let tombstoneKey = "sessionTombstones"

    static func tombstones() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: tombstoneKey) ?? [])
    }

    static func addTombstone(_ id: String) {
        var all = tombstones()
        all.insert(id)
        UserDefaults.standard.set(Array(all), forKey: tombstoneKey)
    }

    /// Stamp a record as shared with the mentor (persisted).
    func markShared(_ id: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].sharedAt = Date()
        save(records[idx])
    }

    /// Merge sessions restored from the cloud (cross-device): insert any record
    /// whose id we don't already have. Local copies win — they're richer
    /// (transcript/turns never leave the device).
    func mergeRestored(_ restored: [ConsultationRecord]) {
        let known = Set(records.map(\.id))
        let dead = Self.tombstones()
        let fresh = restored.filter { !known.contains($0.id) && !dead.contains($0.id) }
        guard !fresh.isEmpty else { return }
        for record in fresh { save(record) }
        records = (records + fresh).sorted { $0.date > $1.date }
    }

    // MARK: - Disk

    private func fileURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }

    private func save(_ record: ConsultationRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: fileURL(record.id), options: [.atomic, .completeFileProtection])
    }

    private func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        records = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ConsultationRecord.self, from: $0) }
            }
            .sorted { $0.date > $1.date }
    }
}
