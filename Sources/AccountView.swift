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
    @State private var displayName = ""
    @State private var creatingAccount = false
    @State private var joinCode = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var resetSent = false
    @AppStorage("privateBackupEnabled") private var backupEnabled = true
    @State private var confirmSignOut = false
    @State private var confirmWipe = false
    /// Raw nonce for the in-flight Sign in with Apple request.
    @State private var appleNonce = ""

    var body: some View {
        NavigationStack {
            Group {
                if account.isSignedIn {
                    Form {
                        signedIn
                        if let errorMessage {
                            Text(errorMessage).font(.caption).foregroundStyle(.red)
                        }
                    }
                } else {
                    signedOutScreen
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

    // MARK: - Signed out (traditional sign-in screen, not a settings form)

    private var signedOutScreen: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image(systemName: "stethoscope.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.blue)
                    Text(creatingAccount ? "Create your account" : "Welcome back")
                        .font(.title2.bold())
                    Text("An account is optional — it lets your history follow you across devices, and you choose what to share with your mentor.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)

                SignInWithAppleButton(creatingAccount ? .signUp : .signIn) { request in
                    appleNonce = Self.randomNonce()
                    request.requestedScopes = [.email, .fullName]
                    request.nonce = Self.sha256(appleNonce)
                } onCompletion: { result in
                    handleApple(result)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                Button {
                    run { try await account.signInWithGoogle() }
                } label: {
                    HStack(spacing: 8) {
                        Text("G").font(.title3.bold()).foregroundStyle(.blue)
                        Text("Continue with Google").font(.body.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                HStack(spacing: 12) {
                    Rectangle().fill(.quaternary).frame(height: 1)
                    Text("or").font(.caption).foregroundStyle(.secondary)
                    Rectangle().fill(.quaternary).frame(height: 1)
                }

                VStack(spacing: 12) {
                    if creatingAccount {
                        TextField("Your name (shown to your mentor)", text: $displayName)
                            .textContentType(.name)
                            .padding(14)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .glassHairline(14)
                    }
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .glassHairline(14)
                    SecureField("Password", text: $password)
                        .textContentType(creatingAccount ? .newPassword : .password)
                        .padding(14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .glassHairline(14)
                }

                Button {
                    run {
                        if creatingAccount {
                            try await account.createAccount(email: email, password: password,
                                                            name: displayName)
                        } else {
                            try await account.signIn(email: email, password: password)
                        }
                    }
                } label: {
                    Group {
                        if busy { ProgressView() }
                        else { Text(creatingAccount ? "Create account" : "Sign in").bold() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || email.isEmpty || password.isEmpty
                          || (creatingAccount && displayName.trimmingCharacters(in: .whitespaces).isEmpty))

                if !creatingAccount {
                    Button(resetSent ? "Reset email sent — check your inbox"
                                     : "Forgot password?") {
                        run {
                            try await account.sendPasswordReset(email: email)
                            resetSent = true
                        }
                    }
                    .font(.footnote)
                    .disabled(busy || email.isEmpty || resetSent)
                }

                if let errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(errorMessage)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }

                if creatingAccount {
                    Text("Your feedback history (scores and redacted highlights — never the recording or transcript) is saved to your private account so it's on all your devices. Only you can see it unless you choose to share a session with a mentor.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    creatingAccount.toggle()
                    errorMessage = nil
                } label: {
                    Text(creatingAccount ? "Already have an account? Sign in"
                                         : "New here? Create an account")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
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
                    Label("Your cohort lives in the Cohort tab", systemImage: "person.2")
                        .font(.caption).foregroundStyle(.secondary)
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
                Text("Enter the code from your program director to connect. Nothing is shared with them until you explicitly choose to.\n\nNo code? No problem — your account works on its own for personal practice, and you can join a program anytime.")
            }
        }

        if account.org != nil {
            Section("Notifications") {
                NotificationsRow()
            }
        }

        Section {
            Toggle("Back up my history to my private account", isOn: $backupEnabled)
        } header: {
            Text("Backup")
        } footer: {
            Text("Scores and redacted highlights — never the recording or transcript — saved to your private account so your history follows you across devices. Only you can see it.")
        }

        Section {
            Button("Sign out", role: .destructive) {
                if FeedbackStore.shared.pendingBackup().isEmpty { account.signOut() }
                else { confirmSignOut = true }
            }
            Button("Remove my data from this device", role: .destructive) {
                confirmWipe = true
            }
        } footer: {
            Text("Removing data deletes your sessions from THIS device only (cloud copies are unaffected). Signing out keeps them on this device, hidden, until you sign back in.")
        }
        .confirmationDialog("Sign out?",
                            isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Wait for backup, then sign out") {
                Task { await PrivateBackup.syncPending(); account.signOut() }
            }
            Button("Sign out now", role: .destructive) { account.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let n = FeedbackStore.shared.pendingBackup().count
            Text("\(n) session\(n == 1 ? "" : "s") haven't finished backing up. They'll stay on this device and back up next time you sign in — nothing is lost.")
        }
        .confirmationDialog("Remove your data from this device?",
                            isPresented: $confirmWipe, titleVisibility: .visible) {
            let pending = FeedbackStore.shared.backedUpCount(for: account.uid).pending
            if pending > 0 {
                Button("Remove anyway (\(pending) not backed up — permanent)", role: .destructive) {
                    FeedbackStore.shared.removeLocal(for: account.uid)
                }
            } else {
                Button("Remove from this device", role: .destructive) {
                    FeedbackStore.shared.removeLocal(for: account.uid)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let pending = FeedbackStore.shared.backedUpCount(for: account.uid).pending
            Text(pending > 0
                 ? "\(pending) session\(pending == 1 ? "" : "s") aren't backed up yet — removing them is permanent and can't be undone."
                 : "Your history is safely backed up. This clears it from this device; sign in on any device to get it back.")
        }
    }

    // MARK: - Helpers

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        errorMessage = nil
        Task {
            do { try await work() }
            catch is CancellationError { /* user backed out — say nothing */ }
            catch { errorMessage = Self.friendlyAuthError(error) }
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
            let name = credential.fullName.map {
                PersonNameComponentsFormatter().string(from: $0)
            }
            run { try await account.signInWithApple(idToken: idToken, rawNonce: nonce,
                                                    fullName: name) }
        }
    }

    /// Human messages for Identity Platform failures (stable FIRAuth codes) —
    /// nobody should read "The supplied auth credential is malformed".
    private static func friendlyAuthError(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == "FIRAuthErrorDomain" else { return error.localizedDescription }
        switch ns.code {
        case 17004, 17009, 17011:   // invalidCredential, wrongPassword, userNotFound
            return "Email or password is incorrect."
        case 17008: return "That doesn't look like an email address."
        case 17012: return "You already have an account with this email — sign in with the method you used before."
        case 17007: return "An account with that email already exists — try signing in instead."
        case 17026: return "Password is too short — use at least 6 characters."
        case 17010: return "Too many attempts — wait a few minutes and try again."
        case 17020: return "Network problem — check your connection and try again."
        default:    return error.localizedDescription
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


/// Notification permission state + the enable path (in-context, post-join).
private struct NotificationsRow: View {
    @ObservedObject private var push = PushManager.shared

    var body: some View {
        switch push.authorized {
        case true:
            Label("Mentor notes notify this device", systemImage: "bell.badge.fill")
                .font(.subheadline)
        case false:
            VStack(alignment: .leading, spacing: 6) {
                Text("Notifications are off — you won't know when your mentor writes to you.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Turn on in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.subheadline)
            }
        case nil:
            Button {
                Task { await push.requestPermission() }
            } label: {
                Label("Notify me about mentor notes", systemImage: "bell.badge")
            }
        case .some(_):
            EmptyView()
        }
    }
}
