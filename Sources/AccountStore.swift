import Foundation
import FirebaseCore
import FirebaseAuth

/// MC2 client: optional accounts via Identity Platform (FirebaseAuth SDK,
/// project-level accounts — NEVER set tenantID) + org membership via invite
/// codes. Contract: medadvisor-cloud/PLAN.md → MC2 Interface (SETTLED).
///
/// Login is OPTIONAL by design — the app is fully functional signed out; an
/// account only unlocks sync/mentor-sharing (MC3+).
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    /// Identity Platform client config (public identifiers, not secrets).
    private enum Config {
        #if DEBUG
        static let apiKey = "AIzaSyBvHos84simxPRf4z8ICERrVz6zhYkayaE"   // medadvisor-dev
        static let googleAppID = "1:743594385075:ios:9bb2092806b7e835149ac6"
        static let projectID = "medadvisor-dev"
        static let gcmSenderID = "743594385075"
        #else
        static let apiKey = "AIzaSyCtAMi8JOzeJWsSaP5yV4WU9FPDsI5ye00"   // medadvisor-production
        static let googleAppID = "1:597896295002:ios:7db9c01f79a5bc79471e63"
        static let projectID = "medadvisor-production"
        static let gcmSenderID = "597896295002"
        #endif
    }

    /// Call once, before any Auth use (app init).
    static func configure() {
        let options = FirebaseOptions(googleAppID: Config.googleAppID,
                                      gcmSenderID: Config.gcmSenderID)
        options.apiKey = Config.apiKey
        options.projectID = Config.projectID
        FirebaseApp.configure(options: options)
        _ = shared   // start the auth-state listener
    }

    struct Org: Codable, Equatable {
        let orgId: String
        let name: String
        let role: String
    }

    @Published private(set) var email: String?
    @Published private(set) var org: Org?
    var isSignedIn: Bool { email != nil }

    private init() {
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.email = user?.email
                if user == nil {
                    self?.org = nil
                } else {
                    await self?.refreshMe()
                    await SessionShare.restore()   // cross-device history (silent)
                }
            }
        }
    }

    // MARK: - Sign in / out

    func signIn(email: String, password: String) async throws {
        try await Auth.auth().signIn(withEmail: email, password: password)
    }

    func createAccount(email: String, password: String) async throws {
        try await Auth.auth().createUser(withEmail: email, password: password)
    }

    /// Completes Sign in with Apple: exchange the Apple identity token (+ the
    /// raw nonce used in the request) for a Firebase session.
    func signInWithApple(idToken: String, rawNonce: String) async throws {
        let credential = OAuthProvider.credential(withProviderID: "apple.com",
                                                  idToken: idToken,
                                                  rawNonce: rawNonce)
        try await Auth.auth().signIn(with: credential)
    }

    func signOut() {
        try? Auth.auth().signOut()
    }

    // MARK: - Org membership

    /// Redeem an invite code. On success the server sets custom claims, so we
    /// MUST force-refresh the ID token before /v1/me reflects the org.
    func redeem(code: String) async throws {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        struct Body: Encodable { let code: String }
        struct Reply: Decodable { let orgId: String; let orgName: String; let role: String }
        let reply: Reply = try await call("v1/invites/redeem", method: "POST", body: Body(code: cleaned))
        if let user = Auth.auth().currentUser {
            _ = try await user.getIDTokenResult(forcingRefresh: true)   // pick up new claims
        }
        org = Org(orgId: reply.orgId, name: reply.orgName, role: reply.role)
    }

    /// Refresh identity + org from the server (silent on failure — offline OK).
    func refreshMe() async {
        struct Me: Decodable { let email: String?; let org: Org? }
        guard let me: Me = try? await call("v1/me", method: "GET", body: Optional<Int>.none) else { return }
        org = me.org
    }

    // MARK: - API plumbing

    enum APIError: LocalizedError {
        case notSignedIn
        case server(Int, String)
        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "You need to be signed in."
            case .server(404, _): return "That code isn't valid (it may have expired)."
            case .server(let status, let code): return "Server error \(status) (\(code))."
            }
        }
    }

    private struct ServerErrorBody: Decodable { let error: String? }

    /// Authed JSON call against the API (also used by SessionShare).
    func call<B: Encodable, R: Decodable>(_ path: String, method: String, body: B?) async throws -> R {
        guard let user = Auth.auth().currentUser else { throw APIError.notSignedIn }
        let token = try await user.getIDTokenResult(forcingRefresh: false).token
        var request = URLRequest(url: RubricSync.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let code = (try? JSONDecoder().decode(ServerErrorBody.self, from: data))?.error ?? "unknown"
            throw APIError.server(status, code)
        }
        return try JSONDecoder().decode(R.self, from: data)
    }
}
