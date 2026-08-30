import SwiftUI

/// "What's new" sheet, shown once per release.
///
/// Written for the medical director rather than for engineers: every entry says
/// what changed *for him*, and anything provisional is labelled as such rather
/// than sold as finished. Entries are ordered newest-release-first; `Release.id`
/// is compared against the last version the user acknowledged, so a returning
/// user sees only what they haven't seen.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    struct Item: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
        /// Flags a feature that is being trialled, so it is never mistaken for
        /// settled behaviour.
        var provisional = false
    }

    struct Release: Identifiable {
        let id: String          // marketing version, e.g. "0.0.6"
        let heading: String
        let items: [Item]
    }

    /// Newest first. Add a Release here when you ship; the sheet handles the rest.
    static let releases: [Release] = [
        Release(id: "0.0.6", heading: "This update", items: [
            Item(icon: "cpu",
                 title: "Choose which AI model reviews your consultations",
                 detail: "Settings → AI Model now lists two. Qwen 2.5-7B is the one you've been using and stays selected unless you change it. Qwen 3.5-4B is newer and about a third smaller, so it downloads faster and runs cooler — but its feedback is still being evaluated, so treat what it says as provisional. Switching keeps both on your phone; you can go back at any time, and nothing you've already recorded is affected.",
                 provisional: true),
            Item(icon: "person.2.fill",
                 title: "See and control what you've shared",
                 detail: "Each session now shows its own sharing status, and a control panel lists everything currently shared with a mentor — so you can check or withdraw access without hunting for it."),
            Item(icon: "key.fill",
                 title: "Invite codes",
                 detail: "Join a mentor's cohort by entering or pasting an invite code. Sessions you recorded before signing in are now claimed automatically, so nothing you did while signed out gets stranded."),
            Item(icon: "bubble.left.and.bubble.right.fill",
                 title: "Mentor chat refreshes live",
                 detail: "Replies from your mentor appear without needing to leave the screen and come back."),
            Item(icon: "chart.xyaxis.line",
                 title: "Skill charts open properly",
                 detail: "The expanded charts on the Progress screen are reachable again."),
        ]),
        Release(id: "0.0.5", heading: "Earlier", items: [
            Item(icon: "icloud.fill",
                 title: "Accounts and mentor sharing",
                 detail: "Sign in to keep your sessions across devices and share a session with a mentor. Signing in stays optional — the app works fully offline without an account."),
            Item(icon: "checklist",
                 title: "Rubrics update without an App Store release",
                 detail: "Assessment criteria are fetched from the cloud, so changes to the mark scheme reach the app without waiting for a new version."),
            Item(icon: "lock.shield.fill",
                 title: "Stronger privacy handling",
                 detail: "Recordings, transcripts and feedback are excluded from iCloud backup, orphaned audio is swept at launch, and signed-in users no longer see anonymous records on a shared device."),
            Item(icon: "scalemass",
                 title: "Stricter, more consistent scoring",
                 detail: "Scoring is now deterministic — the same recording produces the same result — and a criterion is only credited when it can be backed by a direct quote from the transcript."),
        ]),
    ]

    // MARK: - Seen-state

    private static let lastSeenKey = "whatsNewLastSeenVersion"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// True when this build has notes the user hasn't acknowledged yet. First
    /// launch after a fresh install returns false — a brand-new user doesn't
    /// need a changelog for an app they've never used.
    static var shouldPresent: Bool {
        let seen = UserDefaults.standard.string(forKey: lastSeenKey)
        guard let seen else {
            UserDefaults.standard.set(currentVersion, forKey: lastSeenKey)
            return false
        }
        return seen != currentVersion
    }

    static func markSeen() {
        UserDefaults.standard.set(currentVersion, forKey: lastSeenKey)
    }

    // MARK: - View

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(Self.releases) { release in
                        VStack(alignment: .leading, spacing: 18) {
                            Text(release.heading)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            ForEach(release.items) { item in
                                row(item)
                            }
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("What's New")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Self.markSeen(); dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: WhatsNewView.Item) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title).font(.headline)
                    if item.provisional {
                        Text("TRIAL")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
