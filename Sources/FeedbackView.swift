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

                if !feedback.perCriterion.isEmpty {
                    Section("Criteria") {
                        ForEach(feedback.perCriterion) { result in
                            criterionRow(result)
                        }
                    }
                } else {
                    // JSON parse fell back — show the raw model output so nothing is hidden.
                    Section("Model output (unparsed)") {
                        Text(feedback.rawOutput)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
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

    private func criterionText(_ id: String) -> String {
        rubric.criteria.first { $0.id == id }?.prompt ?? id
    }
}
