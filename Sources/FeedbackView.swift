import SwiftUI

/// Feedback for one consultation. Two views via a segmented toggle:
///  • Feedback — an overall score card, critical items, then per-phase cards
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

    // MARK: - Feedback (card layout)

    private var feedbackList: some View {
        ScrollView {
            VStack(spacing: 16) {
                scoreCard
                if !criticalMisses.isEmpty { criticalCard }
                ForEach(orderedDimensions) { dimension in
                    let results = resultsFor(dimension)
                    if !results.isEmpty { phaseCard(dimension, results) }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    /// Top card: big done/total, band pill, proportion bar, summary prose.
    private var scoreCard: some View {
        card {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(overallMet)")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(bandColor)
                Text("of \(overallTotal) done")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(bandLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(bandColor)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(bandColor.opacity(0.15), in: Capsule())
            }

            ScoreBar(met: overallMet, partial: overallPartial, missed: overallMissed)
                .frame(height: 10)

            if let summary = feedback.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
    }

    /// Distinct red card for critical misses.
    private var criticalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Critical — address these first", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.red)
            ForEach(criticalMisses) { result in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(criterionText(result.criterionId))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.red.opacity(0.28)))
    }

    /// One card per phase: header + count pill, then criteria split by dividers.
    private func phaseCard(_ dimension: Dimension, _ results: [CriterionResult]) -> some View {
        card {
            HStack(spacing: 6) {
                if goals.isPinned(dimension.id) {
                    Image(systemName: "pin.fill").foregroundStyle(.orange)
                }
                Text(dimension.label).font(.headline)
                Spacer()
                Text("\(metCount(results))/\(results.count)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }

            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                if index > 0 {
                    Divider().padding(.vertical, 2)
                }
                criterionRow(result)
            }
        }
    }

    private func criterionRow(_ result: CriterionResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: result.status).name)
                .font(.system(size: 18))
                .foregroundStyle(icon(for: result.status).color)
            VStack(alignment: .leading, spacing: 6) {
                Text(criterionText(result.criterionId))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let evidence = result.evidence, !evidence.isEmpty {
                    Text("“\(evidence)”")
                        .font(.caption).italic()
                        .foregroundStyle(.secondary)
                }
                if let comment = result.comment, !comment.isEmpty {
                    Label(comment, systemImage: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    /// Rounded card container.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Transcript

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

    // MARK: - Helpers

    private var overallMet: Int { feedback.perCriterion.filter { $0.status == .met }.count }
    private var overallPartial: Int { feedback.perCriterion.filter { $0.status == .partial }.count }
    private var overallMissed: Int { feedback.perCriterion.filter { $0.status == .missed }.count }
    private var overallTotal: Int { feedback.perCriterion.count }

    private var metFraction: Double {
        overallTotal == 0 ? 0 : Double(overallMet) / Double(overallTotal)
    }
    private var bandLabel: String {
        switch metFraction {
        case ..<0.4:  return "Emerging"
        case ..<0.75: return "Developing"
        default:      return "Proficient"
        }
    }
    private var bandColor: Color {
        switch metFraction {
        case ..<0.4:  return .red
        case ..<0.75: return .orange
        default:      return .green
        }
    }

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

    /// Pinned phase first, then the rubric's order.
    private var orderedDimensions: [Dimension] {
        rubric.dimensions.sorted { a, b in
            let ap = goals.isPinned(a.id) ? 0 : 1
            let bp = goals.isPinned(b.id) ? 0 : 1
            return ap < bp
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

/// A thin stacked proportion bar: met (green) / partial (orange) / missed (red).
private struct ScoreBar: View {
    let met: Int
    let partial: Int
    let missed: Int

    var body: some View {
        GeometryReader { geo in
            let total = CGFloat(max(1, met + partial + missed))
            HStack(spacing: 0) {
                Rectangle().fill(.green)
                    .frame(width: geo.size.width * CGFloat(met) / total)
                Rectangle().fill(.orange)
                    .frame(width: geo.size.width * CGFloat(partial) / total)
                Rectangle().fill(.red)
                    .frame(width: geo.size.width * CGFloat(missed) / total)
            }
        }
        .clipShape(Capsule())
    }
}
