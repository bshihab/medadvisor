import SwiftUI

/// Goal-setting: pick a phase to focus on for the next encounter. Shows why it
/// matters and example phrases (the front half of the coaching loop). Content
/// comes from each rubric dimension's `coaching` block. Presented as iOS 26
/// liquid-glass panes that expand to reveal the coaching.
struct GoalSettingView: View {
    let location: AppLocation

    @ObservedObject private var goals = GoalStore.shared
    @State private var expanded: Set<String> = []
    private var rubric: Rubric? { RubricLoader.load(for: location) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Pin a skill to focus on for your next \(location.rawValue) encounter.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let rubric {
                    ForEach(rubric.dimensions) { dimension in
                        pane(dimension)
                    }
                } else {
                    Text("No rubric available for this location.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle("Focus")
        .navigationBarTitleDisplayMode(.inline)
        .ambientGradient([.orange, .pink, .purple])
    }

    /// One liquid-glass pane per rubric dimension: header (label + pin) that
    /// expands to reveal the coaching. Pinned panes get an orange glass ring.
    private func pane(_ dimension: Dimension) -> some View {
        let pinned = goals.isPinned(dimension.id)
        let open = expanded.contains(dimension.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.smooth(duration: 0.3)) { toggleExpanded(dimension.id) }
                } label: {
                    HStack {
                        Text(dimension.label)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.smooth(duration: 0.3)) { goals.toggle(dimension.id) }
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.headline)
                        .foregroundStyle(pinned ? .orange : .secondary)
                        .padding(10)
                        .glassSurface(in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pinned ? "Unpin \(dimension.label)" : "Pin \(dimension.label)")
            }

            if open {
                coachingContent(dimension)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22))
        .glassHairline(22)
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(pinned ? Color.orange.opacity(0.6) : .clear, lineWidth: 2)
        )
    }

    @ViewBuilder
    private func coachingContent(_ dimension: Dimension) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let why = dimension.coaching?.whyItMatters {
                Text(why).font(.callout).foregroundStyle(.primary)
            }
            if let phrases = dimension.coaching?.examplePhrases, !phrases.isEmpty {
                Text("Try saying")
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}
