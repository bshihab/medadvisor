import SwiftUI

/// The two things a user can do in a session.
enum Mode {
    case recording
    case goalSetting
}

/// Home screen: pick a mode. Each leads to location selection, then the screen.
struct HomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                Text("MedAdvisor")
                    .font(.largeTitle.bold())
                Text("Choose what you'd like to do")
                    .foregroundStyle(.secondary)

                NavigationLink {
                    LocationSelectionView(mode: .recording)
                } label: {
                    ModeCard(title: "Record a Consultation",
                             subtitle: "Record an encounter and get feedback on it",
                             systemImage: "mic.fill",
                             tint: .accentColor)
                }

                NavigationLink {
                    LocationSelectionView(mode: .goalSetting)
                } label: {
                    ModeCard(title: "Set a Goal",
                             subtitle: "Pick a skill to focus on before your next encounter",
                             systemImage: "target",
                             tint: .green)
                }

                NavigationLink {
                    HistoryView()
                } label: {
                    ModeCard(title: "History",
                             subtitle: "Review your past feedback and progress",
                             systemImage: "clock.arrow.circlepath",
                             tint: .indigo)
                }

                Spacer()

                NavigationLink("Developer: on-device LLM test") {
                    LLMSpikeView()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

/// Location selection: 4 cards, shown before the mode's screen.
struct LocationSelectionView: View {
    let mode: Mode

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Where is this encounter?")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(AppLocation.allCases) { location in
                    NavigationLink {
                        destination(for: location)
                    } label: {
                        LocationCard(location: location)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(mode == .recording ? "Record" : "Set a Goal")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func destination(for location: AppLocation) -> some View {
        switch mode {
        case .recording:   RecordingView(location: location)
        case .goalSetting: GoalSettingView(location: location)
        }
    }
}

// MARK: - Cards

struct ModeCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(tint, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.primary)
    }
}

struct LocationCard: View {
    let location: AppLocation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(location.rawValue).font(.headline)
            Text(location.blurb).font(.subheadline).foregroundStyle(.secondary)
            if location.isDraft {
                Text(location.draftNote)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.primary)
    }
}
