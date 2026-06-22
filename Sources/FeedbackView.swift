import SwiftUI

/// Displays the structured feedback for one consultation.
struct FeedbackView: View {
    let feedback: ConsultationFeedback
    let rubric: Rubric

    var body: some View {
        NavigationStack {
            List {
                if let summary = feedback.summary, !summary.isEmpty {
                    Section("Summary") { Text(summary) }
                }

                Section("Criteria (\(metCount)/\(feedback.perCriterion.count) met)") {
                    ForEach(feedback.perCriterion) { result in
                        criterionRow(result)
                    }
                }
            }
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

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
                Text("“\(evidence)”")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            if let comment = result.comment, !comment.isEmpty {
                Text(comment).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var metCount: Int {
        feedback.perCriterion.filter { $0.met }.count
    }

    private func criterionText(_ id: String) -> String {
        rubric.criteria.first { $0.id == id }?.prompt ?? id
    }
}
