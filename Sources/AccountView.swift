import SwiftUI
import AuthenticationServices
import CryptoKit

/// Settings row that opens the account sheet — shows sign-in state at a glance.
struct AccountRow: View {
    @ObservedObject private var account = AccountStore.shared
    @State private var showSheet = false

    var body: some View {
        Button { showSheet = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let email = account.email {
                        Text(email).font(.subheadline)
                        Text(account.org.map { "\($0.name) · \($0.roleLabel)" } ?? "No program joined")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Sign in").font(.subheadline)
                        Text("Optional — unlocks sync & sharing with your mentor")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) { AccountView() }
    }
}

/// Optional sign-in + "Join my program". Skippable by design (HIG: never gate
/// core function on login); the system Apple button is at least as prominent
/// as the email option (App Review 4.8).
struct AccountView: View {
    @ObservedObject private var account = AccountStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var email = ""
    @State private var password = ""
    @State private var creatingAccount = false
    @State private var joinCode = ""
    @State private var busy = false
    @State private var errorMessage: String?
    /// Raw nonce for the in-flight Sign in with Apple request.
    @State private var appleNonce = ""

    var body: some View {
        NavigationStack {
            Form {
                if account.isSignedIn { signedIn } else { signedOut }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(account.isSignedIn ? "Done" : "Not now") { dismiss() }
                }
            }
        }
        .preferredColorScheme(nil)
    }

    // MARK: - Signed out

    @ViewBuilder
    private var signedOut: some View {
        Section {
            Text("An account is optional. It lets your history follow you across devices and — only when you choose — lets you share results with your mentor.")
                .font(.footnote).foregroundStyle(.secondary)
        }

        Section {
            SignInWithAppleButton(.signIn) { request in
                appleNonce = Self.randomNonce()
                request.requestedScopes = [.email]
                request.nonce = Self.sha256(appleNonce)
            } onCompletion: { result in
                handleApple(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 48)
            .listRowInsets(EdgeInsets())
        }

        Section("Or with email") {
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textContentType(creatingAccount ? .newPassword : .password)
            Toggle("I'm new — create an account", isOn: $creatingAccount)
                .font(.subheadline)
            Button(creatingAccount ? "Create account" : "Sign in") {
                run {
                    if creatingAccount {
                        try await account.createAccount(email: email, password: password)
                    } else {
                        try await account.signIn(email: email, password: password)
                    }
                }
            }
            .disabled(busy || email.isEmpty || password.isEmpty)
        }
    }

    // MARK: - Signed in

    @ViewBuilder
    private var signedIn: some View {
        Section("Signed in as") {
            Text(account.email ?? "")
        }

        if let org = account.org {
            Section("Program") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(org.name)
                    Text(org.roleLabel).font(.caption).foregroundStyle(.secondary)
                }
                if org.role == "admin" {
                    NavigationLink {
                        MentorCohortView(org: org)
                    } label: {
                        Label("My cohort", systemImage: "person.2")
                    }
                }
            }
        } else {
            Section {
                TextField("Invite code", text: $joinCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button("Join") {
                    run { try await account.redeem(code: joinCode) }
                }
                .disabled(busy || joinCode.trimmingCharacters(in: .whitespaces).count < 4)
            } header: {
                Text("Join my program")
            } footer: {
                Text("Enter the code from your program director to connect. Nothing is shared with them until you explicitly choose to.")
            }
        }

        Section {
            Button("Sign out", role: .destructive) { account.signOut() }
        }
    }

    // MARK: - Helpers

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        errorMessage = nil
        Task {
            do { try await work() } catch { errorMessage = error.localizedDescription }
            busy = false
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            let ns = error as NSError
            if ns.code != ASAuthorizationError.canceled.rawValue {
                errorMessage = error.localizedDescription
            }
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Apple sign-in returned no identity token."
                return
            }
            let nonce = appleNonce
            run { try await account.signInWithApple(idToken: idToken, rawNonce: nonce) }
        }
    }

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            if SecRandomCopyBytes(kSecRandomDefault, 1, &random) == errSecSuccess,
               random < UInt8(charset.count) * (255 / UInt8(charset.count)) {
                result.append(charset[Int(random) % charset.count])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
