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

    var location: AppLocation? { AppLocation(rawValue: locationRaw) }
}

/// Persists feedback records to disk, encrypted at rest via iOS Data Protection
/// (`.completeFileProtection` — files are unreadable while the device is locked
/// and tied to the device passcode). No keys to manage.
@MainActor
final class FeedbackStore: ObservableObject {
    static let shared = FeedbackStore()

    @Published private(set) var records: [ConsultationRecord] = []

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
        records.removeAll { $0.id == record.id }
        try? FileManager.default.removeItem(at: fileURL(record.id))
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
