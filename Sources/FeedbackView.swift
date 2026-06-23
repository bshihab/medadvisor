import SwiftUI

/// Feedback for one consultation. Two views via a segmented toggle:
///  • Feedback — per-phase X-of-Y-met with evidence + tips
///  • Transcript — the full (redacted, speaker-labeled) conversation
struct FeedbackView: View {
    let feedback: ConsultationFeedback
    let rubric: Rubric
    var transcript: String? = nil

    private enum Tab: Hashable { case feedback, transcript }
    @State private var tab: Tab = .feedback

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if transcript != nil {
                    Picker("View", selection: $tab) {
                        Text("Feedback").tag(Tab.feedback)
                        Text("Transcript").tag(Tab.transcript)
                    }
                    .pickerStyle(.segmented)
                    .padding()
                }

                switch tab {
                case .feedback:   feedbackList
                case .transcript: transcriptView
                }
            }
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Feedback list

    private var feedbackList: some View {
        List {
            if let summary = feedback.summary, !summary.isEmpty {
                Section {
                    Text(summary).foregroundStyle(.primary)
                } header: { header("Summary") }
            }

            if !criticalMisses.isEmpty {
                Section {
                    ForEach(criticalMisses) { result in
                        Label(criterionText(result.criterionId), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fontWeight(.semibold)
                    }
                } header: { header("Critical — address these first") }
            }

            ForEach(rubric.dimensions) { dimension in
                let results = resultsFor(dimension)
                if !results.isEmpty {
                    Section {
                        ForEach(results) { criterionRow($0) }
                    } header: {
                        header("\(dimension.label) — \(metCount(results))/\(results.count) met")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var transcriptView: some View {
        ScrollView {
            Text(transcript ?? "")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
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
                    .foregroundStyle(.primary)
            }
            if let evidence = result.evidence, !evidence.isEmpty {
                Text("“\(evidence)”").font(.caption).italic().foregroundStyle(.secondary)
            }
            if let comment = result.comment, !comment.isEmpty {
                Text(comment).font(.caption).foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 2)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.primary)
            .textCase(nil)   // stop List's default uppercase
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
