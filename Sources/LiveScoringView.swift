import SwiftUI

/// Shows the whole rubric, grouped by phase, filling in live as each criterion
/// is scored: pending (dotted) → in-progress (spinner) → result icon.
struct LiveScoringView: View {
    let rubric: Rubric
    let results: [CriterionResult]

    /// The criterion currently being scored is the next one after those done.
    private var currentId: String? {
        rubric.criteria.indices.contains(results.count)
            ? rubric.criteria[results.count].id : nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(rubric.dimensions) { dim in
                        let items = rubric.criteria.filter { $0.dimension == dim.id }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(dim.label)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(items) { row(for: $0).id($0.id) }
                            }
                        }
                    }
                    // Anchor so the last criterion can scroll clear of the bottom.
                    Color.clear.frame(height: 1).id("scoring-bottom")
                }
                .padding()
                .animation(.easeInOut(duration: 0.3), value: results.count)
            }
            // Follow the criterion being scored as the rubric fills downward.
            .onChange(of: results.count) { _, _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(currentId ?? "scoring-bottom", anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for c: Criterion) -> some View {
        HStack(alignment: .top, spacing: 12) {
            marker(for: c.id).frame(width: 24, height: 24)
            Text(c.prompt)
                .font(.subheadline)
                .foregroundStyle(result(for: c.id) == nil ? .secondary : .primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func marker(for id: String) -> some View {
        if let r = result(for: id) {
            let icon = Self.icon(for: r.status)
            Image(systemName: icon.name)
                .font(.system(size: 20))
                .foregroundStyle(icon.color)
                .transition(.scale.combined(with: .opacity))
        } else if id == currentId {
            ProgressView().scaleEffect(0.8)
        } else {
            Image(systemName: "circle.dotted")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
        }
    }

    private func result(for id: String) -> CriterionResult? {
        results.first { $0.criterionId == id }
    }

    static func icon(for status: CriterionResult.Status) -> (name: String, color: Color) {
        switch status {
        case .met:     return ("checkmark.circle.fill", .green)
        case .partial: return ("exclamationmark.circle.fill", .orange)
        case .missed:  return ("xmark.circle.fill", .red)
        }
    }
}
