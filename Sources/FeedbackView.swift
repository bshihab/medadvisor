import SwiftUI

/// Feedback for one consultation. Two views via a segmented toggle:
///  • Feedback — per-phase X-of-Y-met with evidence + tips
///  • Transcript — the full (redacted, speaker-labeled) conversation
struct FeedbackView: View {
    let feedback: ConsultationFeedback
    let rubric: Rubric
    var transcript: String? = nil
    var turns: [TranscriptTurn]? = nil

    private var hasTranscript: Bool {
        (turns?.isEmpty == false) || (transcript?.isEmpty == false)
    }

    private enum Tab: Hashable { case feedback, transcript }
    @State private var tab: Tab = .feedback
    @ObservedObject private var goals = GoalStore.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if hasTranscript {
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
            .toolbar {
                if tab == .transcript && !shareText.isEmpty {
                    ShareLink(item: shareText)
                }
            }
        }
    }

    /// Full transcript as plain text for the Share button.
    private var shareText: String {
        if let turns, !turns.isEmpty {
            return turns.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        }
        return transcript ?? ""
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

            ForEach(orderedDimensions) { dimension in
                let results = resultsFor(dimension)
                if !results.isEmpty {
                    Section {
                        ForEach(results) { criterionRow($0) }
                    } header: {
                        pinnedHeader(dimension, results: results)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var transcriptView: some View {
        if let turns, !turns.isEmpty {
            ChatTranscriptView(turns: turns)
        } else {
            ScrollView {
                Text(transcript ?? "")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func criterionRow(_ result: CriterionResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(for: result.status).name)
                    .foregroundStyle(icon(for: result.status).color)
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

    /// Section header that flags the pinned focus phase with an orange pin.
    @ViewBuilder
    private func pinnedHeader(_ dimension: Dimension, results: [CriterionResult]) -> some View {
        HStack(spacing: 6) {
            if goals.isPinned(dimension.id) {
                Image(systemName: "pin.fill").foregroundStyle(.orange)
            }
            header("\(dimension.label) — \(metCount(results))/\(results.count) met")
        }
    }

    /// Pinned phase first, then the rubric's order.
    private var orderedDimensions: [Dimension] {
        rubric.dimensions.sorted { a, b in
            let ap = goals.isPinned(a.id) ? 0 : 1
            let bp = goals.isPinned(b.id) ? 0 : 1
            return ap < bp
        }
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
        results.filter { $0.status == .met }.count
    }
    private var criticalMisses: [CriterionResult] {
        feedback.perCriterion.filter {
            $0.status == .missed && (criterion(for: $0.criterionId)?.criticalFail ?? false)
        }
    }

    /// Icon + colour per status: done ✓ green, partial ⚠️ orange, missed ✗ red.
    private func icon(for status: CriterionResult.Status) -> (name: String, color: Color) {
        switch status {
        case .met:     return ("checkmark.circle.fill", .green)
        case .partial: return ("exclamationmark.circle.fill", .orange)
        case .missed:  return ("xmark.circle.fill", .red)
        }
    }
}
