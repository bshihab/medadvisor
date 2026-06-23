import SwiftUI

/// Goal-setting mode: pick a phase to focus on for the next encounter. Shows
/// why it matters and example phrases (the front half of the coaching loop).
/// Content comes from each rubric dimension's `coaching` block.
struct GoalSettingView: View {
    let location: AppLocation

    @ObservedObject private var goals = GoalStore.shared
    private var rubric: Rubric? { RubricLoader.load(for: location) }

    var body: some View {
        List {
            Section {
                Text("Pick a skill to focus on for your next \(location.rawValue) encounter.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let rubric {
                ForEach(rubric.dimensions) { dimension in
                    DisclosureGroup {
                        coachingContent(dimension)
                    } label: {
                        HStack {
                            Text(dimension.label)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Spacer()
                            Button {
                                goals.toggle(dimension.id)
                            } label: {
                                Image(systemName: goals.isPinned(dimension.id) ? "pin.fill" : "pin")
                                    .foregroundStyle(goals.isPinned(dimension.id) ? .orange : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Text("No rubric available for this location.")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Set a Goal")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func coachingContent(_ dimension: Dimension) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let why = dimension.coaching?.whyItMatters {
                Text(why).font(.callout)
            }
            if let phrases = dimension.coaching?.examplePhrases, !phrases.isEmpty {
                Text("Try saying:")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(phrases, id: \.self) { phrase in
                    Text("“\(phrase)”")
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
