import Foundation
import UIKit
import FirebaseCore
import FirebaseAuth
import GoogleSignIn

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
        static let googleClientID = "743594385075-k98bthp09fubpvsk54ni65ji8ic5ia1j.apps.googleusercontent.com"
        #else
        static let apiKey = "AIzaSyCtAMi8JOzeJWsSaP5yV4WU9FPDsI5ye00"   // medadvisor-production
        static let googleAppID = "1:597896295002:ios:7db9c01f79a5bc79471e63"
        static let projectID = "medadvisor-production"
        static let gcmSenderID = "597896295002"
        static let googleClientID = "597896295002-fsm8d0j9tsqjmsh5i2pq4gttio9psen5.apps.googleusercontent.com"
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
        /// User-facing role name (server keeps admin/trainee internally).
        var roleLabel: String { role == "admin" ? "Mentor" : "Trainee" }
    }

    @Published private(set) var email: String?
    @Published private(set) var uid: String?
    @Published private(set) var org: Org?
    var isSignedIn: Bool { email != nil }

    private init() {
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.email = user?.email
                self?.uid = user?.uid
                FeedbackStore.shared.currentUid = user?.uid
                if user == nil {
                    self?.org = nil
                } else {
                    await self?.refreshMe()
                    await SessionShare.restore()   // cross-device history (silent)
                    await NotesStore.shared.refresh()
                    PushManager.shared.syncAfterSignIn()
                }
            }
        }
    }

    // MARK: - Sign in / out

    func signIn(email: String, password: String) async throws {
        try await Auth.auth().signIn(withEmail: email, password: password)
    }

    func createAccount(email: String, password: String, name: String) async throws {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let change = result.user.createProfileChangeRequest()
            change.displayName = trimmed
            try? await change.commitChanges()   // best-effort; account works regardless
            // Refresh the ID token so the name claim rides along immediately —
            // the invite-redeem stores displayName from the TOKEN, and the
            // cached one predates the profile commit.
            _ = try? await result.user.getIDTokenResult(forcingRefresh: true)
        }
    }

    /// Completes Sign in with Apple: exchange the Apple identity token (+ the
    /// raw nonce used in the request) for a Firebase session.
    func signInWithApple(idToken: String, rawNonce: String, fullName: String?) async throws {
        let credential = OAuthProvider.credential(withProviderID: "apple.com",
                                                  idToken: idToken,
                                                  rawNonce: rawNonce)
        let result = try await Auth.auth().signIn(with: credential)
        // Apple only provides the name on the FIRST authorization — capture it
        // then or lose it.
        if let fullName, !fullName.isEmpty,
           (result.user.displayName ?? "").isEmpty {
            let change = result.user.createProfileChangeRequest()
            change.displayName = fullName
            try? await change.commitChanges()
            _ = try? await result.user.getIDTokenResult(forcingRefresh: true)
        }
    }

    /// Continue with Google: native GoogleSignIn flow → Firebase credential.
    /// User-cancel is rethrown as CancellationError so the UI stays silent.
    func signInWithGoogle() async throws {
        guard let presenter = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController })
            .first else {
            throw APIError.server(0, "no_presenter")
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: Config.googleClientID)
        let result: GIDSignInResult
        do {
            result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        } catch {
            let ns = error as NSError
            if ns.domain == kGIDSignInErrorDomain, ns.code == GIDSignInError.canceled.rawValue {
                throw CancellationError()
            }
            throw error
        }
        guard let idToken = result.user.idToken?.tokenString else {
            throw APIError.server(0, "google_no_token")
        }
        let credential = GoogleAuthProvider.credential(withIDToken: idToken,
                                                       accessToken: result.user.accessToken.tokenString)
        let auth = try await Auth.auth().signIn(with: credential)
        if (auth.user.displayName ?? "").isEmpty, let name = result.user.profile?.name {
            let change = auth.user.createProfileChangeRequest()
            change.displayName = name
            try? await change.commitChanges()
            _ = try? await auth.user.getIDTokenResult(forcingRefresh: true)
        }
    }

    func signOut() {
        Task {
            // Withdraw this device's push token while the auth token still
            // works, then sign out.
            await PushManager.shared.unregisterForSignOut()
            try? Auth.auth().signOut()
        }
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
        // In-context permission moment: you just joined a program — a mentor
        // now exists who might write to you.
        await PushManager.shared.requestPermission()
    }

    /// Refresh identity + org from the server (silent on failure — offline OK).
    func refreshMe() async {
        struct Me: Decodable { let uid: String?; let email: String?; let org: Org? }
        guard let me: Me = try? await call("v1/me", method: "GET", body: Optional<Int>.none) else { return }
        uid = me.uid
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

    /// Authed call with no response body of interest (DELETE etc.).
    func callVoid(_ path: String, method: String) async throws {
        guard let user = Auth.auth().currentUser else { throw APIError.notSignedIn }
        let token = try await user.getIDTokenResult(forcingRefresh: false).token
        guard let url = URL(string: path, relativeTo: RubricSync.baseURL) else {
            throw APIError.server(0, "bad_path")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let code = (try? JSONDecoder().decode(ServerErrorBody.self, from: data))?.error ?? "unknown"
            throw APIError.server(status, code)
        }
    }

    /// Authed call whose body is a raw JSON object (lossless round-trips for
    /// the rubric editor — typed encode would drop unknown keys). Returns the
    /// raw response data for the caller to decode.
    func callJSONObject(_ path: String, method: String, jsonObject: Any) async throws -> Data {
        guard let user = Auth.auth().currentUser else { throw APIError.notSignedIn }
        let token = try await user.getIDTokenResult(forcingRefresh: false).token
        guard let url = URL(string: path, relativeTo: RubricSync.baseURL) else {
            throw APIError.server(0, "bad_path")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let code = (try? JSONDecoder().decode(ServerErrorBody.self, from: data))?.error ?? "unknown"
            throw APIError.server(status, code)
        }
        return data
    }

    /// Authed JSON call against the API (also used by SessionShare).
    func call<B: Encodable, R: Decodable>(_ path: String, method: String, body: B?) async throws -> R {
        guard let user = Auth.auth().currentUser else { throw APIError.notSignedIn }
        let token = try await user.getIDTokenResult(forcingRefresh: false).token
        // relative-URL init (not appendingPathComponent) so paths may carry
        // query strings like "v1/orgs/x/sessions?uid=y"
        guard let url = URL(string: path, relativeTo: RubricSync.baseURL) else {
            throw APIError.server(0, "bad_path")
        }
        var request = URLRequest(url: url)
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
