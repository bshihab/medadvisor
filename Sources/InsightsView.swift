import SwiftUI

struct Insights: Equatable {
    let narrative: String
    let strengths: [String]      // evidence quotes from things done well
    let improvements: [String]   // improvement tips
    let encounters: Int
}

/// Aggregates the last several saved consultations and asks the on-device LLM
/// for a short "how you're doing / what to work on" summary.
@MainActor
final class InsightsEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case generating
        case done(Insights)
        case error(String)
    }

    @Published var state: State = .idle

    func generate() async {
        let records = Array(FeedbackStore.shared.records.prefix(6))
        guard !records.isEmpty else {
            state = .error("Record a few consultations first, then come back here.")
            return
        }
        state = .generating

        var met = 0, total = 0
        var strengths: [String] = []
        var improvements: [String] = []
        for record in records {
            for criterion in record.feedback.perCriterion {
                total += 1
                if criterion.met {
                    met += 1
                    if let evidence = criterion.evidence, !evidence.isEmpty, strengths.count < 6 {
                        strengths.append(evidence)
                    }
                } else if let tip = criterion.comment, !tip.isEmpty, improvements.count < 6 {
                    improvements.append(tip)
                }
            }
        }

        let prompt = """
        You are a supportive clinical communication coach. A doctor has completed \(records.count) \
        recorded consultations, meeting \(met) of \(total) assessed behaviors overall.

        Things they did well (quotes from their consultations):
        \(strengths.map { "- \"\($0)\"" }.joined(separator: "\n"))

        Areas flagged for improvement:
        \(improvements.map { "- \($0)" }.joined(separator: "\n"))

        Write a short, encouraging summary (4-5 sentences) of their communication across these \
        encounters: what they consistently do well, and the 1-2 most important things to focus on \
        next. Speak directly to the doctor using "you".
        """

        do {
            let narrative = try await LLMEngine.shared.generate(prompt: prompt, maxTokens: 320)
            state = .done(Insights(narrative: narrative,
                                   strengths: strengths,
                                   improvements: improvements,
                                   encounters: records.count))
        } catch {
            state = .error("Couldn't generate insights: \(error.localizedDescription)")
        }
    }
}

struct InsightsView: View {
    @StateObject private var engine = InsightsEngine()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch engine.state {
                case .idle:
                    Text("Get a summary of your recent consultations and what to work on next.")
                        .foregroundStyle(.secondary)
                    Button("Generate insights") { Task { await engine.generate() } }
                        .buttonStyle(.borderedProminent)
                case .generating:
                    ProgressView("Reviewing your recent encounters…")
                case .done(let insights):
                    content(insights)
                case .error(let message):
                    Text(message).foregroundStyle(.secondary)
                    Button("Try again") { Task { await engine.generate() } }
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Insights")
    }

    @ViewBuilder
    private func content(_ insights: Insights) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Across your last \(insights.encounters) encounters")
                .font(.headline)
                .foregroundStyle(.primary)

            Text(insights.narrative)
                .foregroundStyle(.primary)

            if !insights.strengths.isEmpty {
                section("What you did well") {
                    ForEach(insights.strengths, id: \.self) { quote in
                        Text("“\(quote)”").font(.callout).italic().foregroundStyle(.secondary)
                    }
                }
            }

            if !insights.improvements.isEmpty {
                section("Focus areas") {
                    ForEach(insights.improvements, id: \.self) { tip in
                        Text("• \(tip)").font(.callout).foregroundStyle(.primary)
                    }
                }
            }

            Button("Regenerate") { Task { await engine.generate() } }
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.bold)).foregroundStyle(.primary)
            content()
        }
    }
}
