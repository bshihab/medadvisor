import SwiftUI

/// Displays feedback grouped by encounter phase (the 5 dimensions), with an
/// X-of-Y-met count per phase. No single 0–100 score — per the director's
/// formative (not graded) approach.
struct FeedbackView: View {
    let feedback: ConsultationFeedback
    let rubric: Rubric

    var body: some View {
        NavigationStack {
            List {
                if let summary = feedback.summary, !summary.isEmpty {
                    Section("Summary") { Text(summary) }
                }

                if !criticalMisses.isEmpty {
                    Section {
                        ForEach(criticalMisses) { result in
                            Label(criterionText(result.criterionId), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.subheadline)
                        }
                    } header: {
                        Text("Critical — address these first")
                    }
                }

                ForEach(rubric.dimensions) { dimension in
                    let results = resultsFor(dimension)
                    if !results.isEmpty {
                        Section("\(dimension.label) — \(metCount(results))/\(results.count) met") {
                            ForEach(results) { criterionRow($0) }
                        }
                    }
                }
            }
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func criterionRow(_ result: CriterionResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: result.met ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(result.met ? .green : .orange)
                Text(criterionText(result.criterionId))
                    .font(.subheadline.weight(.semibold))
            }
            if let evidence = result.evidence, !evidence.isEmpty {
                Text("“\(evidence)”").font(.caption).italic().foregroundStyle(.secondary)
            }
            if let comment = result.comment, !comment.isEmpty {
                Text(comment).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func criterion(for id: String) -> Criterion? {
        rubric.criteria.first { $0.id == id }
    }

    private func criterionText(_ id: String) -> String {
        criterion(for: id)?.prompt ?? id
    }

    private func resultsFor(_ dimension: Dimension) -> [CriterionResult] {
        feedback.perCriterion.filter { criterion(for: $0.criterionId)?.dimension == dimension.id }
    }

    private func metCount(_ results: [CriterionResult]) -> Int {
        results.filter { $0.met }.count
    }

    private var criticalMisses: [CriterionResult] {
        feedback.perCriterion.filter { !$0.met && (criterion(for: $0.criterionId)?.criticalFail ?? false) }
    }
}
