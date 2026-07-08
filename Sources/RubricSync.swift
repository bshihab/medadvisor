import Foundation

/// MC1 client: keeps the bundled rubrics fresh from the cloud, so the director
/// can update guidelines without an app release.
///
/// On launch, fetches `GET /v1/rubrics` and persists each item's raw envelope
/// to Documents/rubric-cache/<id>.json. `RubricLoader` prefers that cache and
/// falls back to the bundled JSON — airplane mode or any fetch failure never
/// breaks anything (worst case: yesterday's rubric).
/// Envelope spec: medadvisor-cloud/PLAN.md → MC1 Interface (SETTLED 2026-07-08).
enum RubricSync {
    #if DEBUG
    static let baseURL = URL(string: "https://medadvisor-api-743594385075.us-west1.run.app")!   // dev
    #else
    static let baseURL = URL(string: "https://medadvisor-api-597896295002.us-west1.run.app")!   // prod
    #endif

    static var cacheDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("rubric-cache", isDirectory: true)
    }

    /// Fire-and-forget refresh — call once at launch. Silent on any failure.
    static func refresh() {
        Task.detached(priority: .utility) {
            do {
                let url = baseURL.appendingPathComponent("v1/rubrics")
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                // Re-serialize per item with JSONSerialization so rubric keys our
                // Swift model doesn't declare (scoring, etc.) survive on disk —
                // a typed decode/encode round-trip would silently drop them.
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = root["rubrics"] as? [[String: Any]] else { return }
                let dir = cacheDirectory
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var saved = 0
                for item in items {
                    guard let id = item["id"] as? String,
                          id.range(of: #"^[a-z0-9\-]+$"#, options: .regularExpression) != nil
                    else { continue }
                    let itemData = try JSONSerialization.data(withJSONObject: item)
                    // A cloud rubric may only shadow the bundle if it decodes
                    // into our model — a malformed edit can't brick scoring.
                    guard (try? JSONDecoder().decode(Envelope.self, from: itemData)) != nil else { continue }
                    try itemData.write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
                    saved += 1
                }
                print("[RubricSync] refreshed \(saved)/\(items.count) rubric(s)")
            } catch {
                // Offline / server down — cache or bundle serves. By design.
                print("[RubricSync] refresh skipped: \(error.localizedDescription)")
            }
        }
    }

    /// Cached cloud rubric, if one is on disk and valid.
    static func cached(named name: String) -> Rubric? {
        let url = cacheDirectory.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        return envelope.rubric
    }

    /// The versioned envelope served by the API.
    struct Envelope: Codable {
        let id: String
        let version: String?
        let updatedAt: String
        let rubric: Rubric
    }
}
