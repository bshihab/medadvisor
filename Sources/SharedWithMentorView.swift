import SwiftUI

/// "Shared with your mentor" — the trainee's control panel over what the mentor
/// can actually see, read from the SERVER (not the local copies).
///
/// Why this exists: deleting a session locally with "Delete for me" used to end
/// the trainee's ability to retract the mentor's copy — the only button that
/// could do it disappeared with the local record. Retraction now lives here,
/// decoupled from local storage, so it works after a local delete, on a new
/// phone, or after a reinstall.
struct SharedWithMentorView: View {
    @ObservedObject private var account = AccountStore.shared

    @State private var sessions: [SessionShare.SharedSummary] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var removing: Set<String> = []
    @State private var confirmTarget: SessionShare.SharedSummary?

    var body: some View {
        List {
            Section {
                if loading {
                    HStack { ProgressView(); Text("Checking…").foregroundStyle(.secondary) }
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                        Button("Try again") { Task { await load() } }.font(.footnote)
                    }
                } else if sessions.isEmpty {
                    Text("Nothing shared. Your mentor can't see any of your sessions.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(sessions) { session in
                        row(session)
                    }
                }
            } header: {
                Text(account.org.map { "Visible to \($0.name)" } ?? "Shared")
            } footer: {
                Text("This is what your mentor can see right now. Removing a session deletes their copy and any notes attached to it — your own history is unaffected.")
            }
        }
        .navigationTitle("Shared with mentor")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            "Remove this session from your mentor?",
            isPresented: Binding(get: { confirmTarget != nil },
                                 set: { if !$0 { confirmTarget = nil } }),
            titleVisibility: .visible
        ) {
            if let target = confirmTarget {
                Button("Remove from mentor", role: .destructive) {
                    let id = target.clientSessionId
                    confirmTarget = nil
                    Task { await remove(id) }
                }
            }
            Button("Cancel", role: .cancel) { confirmTarget = nil }
        } message: {
            Text("Your mentor loses their copy and any notes they wrote on it. Your own copy of this session stays on your device.")
        }
    }

    @ViewBuilder
    private func row(_ session: SessionShare.SharedSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.recordedAt.map { $0.formatted(date: .abbreviated, time: .shortened) }
                     ?? "Unknown date")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if removing.contains(session.clientSessionId) {
                    ProgressView()
                } else {
                    Button("Remove") { confirmTarget = session }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            Text([session.location, "\(session.met) of \(session.applicable) met"]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func load() async {
        errorMessage = nil
        guard account.org != nil else {
            sessions = []; loading = false
            return
        }
        do {
            sessions = try await SessionShare.fetchShared()
        } catch {
            errorMessage = "Couldn't check what's shared. \(error.localizedDescription)"
        }
        loading = false
    }

    private func remove(_ clientSessionId: String) async {
        removing.insert(clientSessionId)
        defer { removing.remove(clientSessionId) }
        do {
            try await SessionShare.deleteEverywhere(clientSessionId)
            sessions.removeAll { $0.clientSessionId == clientSessionId }
            // Keep the local record honest: it's no longer shared.
            FeedbackStore.shared.markUnshared(clientSessionId)
        } catch {
            errorMessage = "Couldn't remove it — try again when you're online. (\(error.localizedDescription))"
        }
    }
}
