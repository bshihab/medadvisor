import SwiftUI

/// The two things a user can do in a session.
enum Mode {
    case recording
    case goalSetting
}

/// Location selection: 4 cards, shown before the mode's screen.
struct LocationSelectionView: View {
    let mode: Mode

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text(mode == .recording ? "Where is this encounter?" : "Pick a location to set a goal")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(AppLocation.allCases) { location in
                    NavigationLink {
                        destination(for: location)
                    } label: {
                        LocationCard(location: location)
                    }
                    .buttonStyle(.plain)
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

struct LocationCard: View {
    let location: AppLocation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(location.rawValue)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(location.blurb)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if location.isDraft {
                Text(location.draftNote)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }
}
