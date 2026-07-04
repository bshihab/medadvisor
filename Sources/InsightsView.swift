import SwiftUI
import Charts

/// One consultation's score, for the trend chart.
struct SessionPoint: Codable, Equatable, Identifiable {
    let id: String
    let date: Date
    let met: Int
    let total: Int
    var metFraction: Double { total == 0 ? 0 : Double(met) / Double(total) }
}

/// Aggregate met-rate for one rubric dimension across the reviewed sessions,
/// for the "by skill area" bar chart.
struct DimensionScore: Codable, Equatable, Identifiable {
    let id: String       // dimension id
    let label: String
    let met: Int
    let total: Int
    var fraction: Double { total == 0 ? 0 : Double(met) / Double(total) }
}

/// A generated insight report over a date range. Persisted so it survives
/// relaunches and can be regenerated.
struct Insights: Codable, Equatable {
    let narrative: String
    let strengths: [String]      // evidence quotes from things done well
    let improvements: [String]   // improvement tips
    let encounters: Int
    let generatedAt: Date
    let fromDate: Date
    let toDate: Date
    let trend: [SessionPoint]    // chronological (oldest first)
    let improvementPoints: Double?   // change in met% first-half → second-half
    let dimensionScores: [DimensionScore]?   // per-skill-area aggregate (optional/back-compat)
}

/// Persists the single most-recent insight (encrypted at rest).
@MainActor
final class InsightStore {
    static let shared = InsightStore()
    private let fileURL: URL

    init() {
        fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("insights.json")
    }

    func load() -> Insights? {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Insights.self, from: $0) }
    }
    func save(_ insights: Insights) {
        guard let data = try? JSONEncoder().encode(insights) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

@MainActor
final class InsightsEngine: ObservableObject {
    @Published var latest: Insights?
    @Published var isGenerating = false
    @Published var errorMessage: String?

    func loadSaved() {
        if latest == nil { latest = InsightStore.shared.load() }
    }

    func generate(from: Date, to: Date) async {
        errorMessage = nil
        let records = FeedbackStore.shared.records
            .filter { $0.date >= from && $0.date <= to.addingTimeInterval(86_400) }
            .sorted { $0.date < $1.date }   // oldest first

        guard !records.isEmpty else {
            errorMessage = "No consultations in that date range. Pick a wider range or record more."
            return
        }
        isGenerating = true
        defer { isGenerating = false }

        let trend = records.map {
            SessionPoint(id: $0.id, date: $0.date,
                         met: $0.feedback.metCount, total: $0.feedback.total)
        }

        var met = 0, total = 0
        var strengths: [String] = []
        var improvements: [String] = []
        for record in records {
            for criterion in record.feedback.perCriterion {
                if criterion.status == .notApplicable { continue }   // not an assessed behavior
                total += 1
                if criterion.status == .met {
                    met += 1
                    if let evidence = criterion.evidence, !evidence.isEmpty, strengths.count < 6 {
                        strengths.append(evidence)
                    }
                } else if let tip = criterion.comment, !tip.isEmpty, improvements.count < 6 {
                    improvements.append(tip)
                }
            }
        }

        // Per-dimension aggregate across all reviewed sessions (N/A excluded),
        // in each rubric's dimension order.
        var dimAgg: [String: (label: String, met: Int, total: Int)] = [:]
        var dimOrder: [String] = []
        for record in records {
            guard let rubric = RubricLoader.load(for: record.location ?? .outpatientClinic) else { continue }
            if dimOrder.isEmpty { dimOrder = rubric.dimensions.map(\.id) }
            let dimOf = Dictionary(rubric.criteria.map { ($0.id, $0.dimension) }, uniquingKeysWith: { a, _ in a })
            let labelOf = Dictionary(rubric.dimensions.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
            for criterion in record.feedback.perCriterion where criterion.status != .notApplicable {
                guard let dimId = dimOf[criterion.criterionId] else { continue }
                var entry = dimAgg[dimId] ?? (labelOf[dimId] ?? dimId, 0, 0)
                entry.total += 1
                if criterion.status == .met { entry.met += 1 }
                dimAgg[dimId] = entry
            }
        }
        let dimensionScores: [DimensionScore] = dimOrder.compactMap { id in
            guard let e = dimAgg[id] else { return nil }
            return DimensionScore(id: id, label: e.label, met: e.met, total: e.total)
        }

        let improvement = Self.improvementPoints(trend)
        let prompt = """
        You are a supportive clinical communication coach. A doctor completed \(records.count) \
        recorded consultations, meeting \(met) of \(total) assessed behaviors overall.
        \(improvement.map { "Their met-rate changed by \(Int($0)) points from their earlier to later sessions in this period." } ?? "")

        Things they did well (quotes):
        \(strengths.map { "- \"\($0)\"" }.joined(separator: "\n"))

        Areas flagged for improvement:
        \(improvements.map { "- \($0)" }.joined(separator: "\n"))

        Write a short, encouraging summary (4-5 sentences): what they consistently do well, whether \
        they're improving, and the 1-2 most important things to focus on next. Speak directly using "you".
        """

        do {
            let narrative = try await LLMEngine.shared.generate(prompt: prompt, maxTokens: 320)
            let insights = Insights(narrative: narrative,
                                    strengths: strengths,
                                    improvements: improvements,
                                    encounters: records.count,
                                    generatedAt: Date(),
                                    fromDate: from, toDate: to,
                                    trend: trend,
                                    improvementPoints: improvement,
                                    dimensionScores: dimensionScores)
            latest = insights
            InsightStore.shared.save(insights)
        } catch {
            errorMessage = "Couldn't generate insights: \(error.localizedDescription)"
        }
    }

    /// Change in average met-fraction (percentage points) from the first half of
    /// sessions to the second half. Nil if fewer than 2 sessions.
    static func improvementPoints(_ points: [SessionPoint]) -> Double? {
        guard points.count >= 2 else { return nil }
        let mid = points.count / 2
        let first = points.prefix(mid)
        let second = points.suffix(points.count - mid)
        let a = first.map(\.metFraction).reduce(0, +) / Double(first.count)
        let b = second.map(\.metFraction).reduce(0, +) / Double(second.count)
        return (b - a) * 100
    }
}

struct InsightsView: View {
    @StateObject private var engine = InsightsEngine()
    @State private var showPicker = false
    @State private var fromDate = Date().addingTimeInterval(-30 * 86_400)
    @State private var toDate = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if engine.isGenerating {
                    GeneratingInsights(title: "Reviewing your consultations…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else if let insights = engine.latest {
                    report(insights)
                } else {
                    intro
                }
                if let errorMessage = engine.errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Insights")
        .ambientGradient([.teal, .blue, .indigo])
        .onAppear {
            engine.loadSaved()
            setDefaultRange()
        }
        .sheet(isPresented: $showPicker) { dateRangeSheet }
    }

    // MARK: - States

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Get a summary of your consultations over a date range — how you're doing, whether you're improving, and what to work on next.")
                .foregroundStyle(.secondary)
            Button {
                setDefaultRange(); showPicker = true
            } label: {
                Label("Generate insights", systemImage: "sparkles")
            }
            .glassButton(prominent: true)
        }
    }

    @ViewBuilder
    private func report(_ insights: Insights) -> some View {
        // Header: last generated + date range + regenerate
        card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last generated \(insights.generatedAt, format: .dateTime.month().day().hour().minute())")
                        .font(.subheadline.weight(.semibold))
                    Text("From \(insights.fromDate, format: .dateTime.month().day().year()) to \(insights.toDate, format: .dateTime.month().day().year())")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showPicker = true } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .glassButton()
                .controlSize(.small)
            }
        }

        // Metrics: encounters + improvement + trend chart
        card {
            HStack(spacing: 20) {
                metric("\(insights.encounters)", "consultations")
                if let imp = insights.improvementPoints {
                    Divider().frame(height: 36)
                    improvementMetric(imp)
                }
            }
            Text("Done-rate per session")
                .font(.caption).foregroundStyle(.secondary)
            trendChart(insights.trend)
        }

        // By skill area — per-dimension bars
        if let dims = insights.dimensionScores, !dims.isEmpty {
            card {
                Text("By skill area")
                    .font(.subheadline.weight(.bold))
                Text("Average done-rate across these sessions")
                    .font(.caption).foregroundStyle(.secondary)
                dimensionChart(dims)
            }
        }

        // Narrative
        card {
            Text("Coach's summary").font(.subheadline.weight(.bold))
            Text(insights.narrative).font(.subheadline)
        }

        if !insights.strengths.isEmpty {
            card {
                Text("What you did well").font(.subheadline.weight(.bold))
                ForEach(insights.strengths, id: \.self) { quote in
                    Text("“\(quote)”").font(.callout).italic().foregroundStyle(.secondary)
                }
            }
        }
        if !insights.improvements.isEmpty {
            card {
                Text("Focus areas").font(.subheadline.weight(.bold))
                ForEach(insights.improvements, id: \.self) { tip in
                    Label(tip, systemImage: "lightbulb").font(.callout).foregroundStyle(.primary)
                }
            }
        }
    }

    // MARK: - Chart + metrics

    private func trendChart(_ points: [SessionPoint]) -> some View {
        Chart(points) { point in
            PointMark(x: .value("Date", point.date),
                      y: .value("Done %", point.metFraction * 100))
                .foregroundStyle(ScoreBand.color(point.metFraction))
        }
        .chartYScale(domain: 0...100)
        .frame(height: 180)
    }

    /// Horizontal bars, one per rubric dimension, colored by score band.
    private func dimensionChart(_ dims: [DimensionScore]) -> some View {
        Chart(dims) { dim in
            BarMark(
                x: .value("Done %", dim.fraction * 100),
                y: .value("Skill area", dim.label)
            )
            .foregroundStyle(ScoreBand.color(dim.fraction))
            .cornerRadius(4)
            .annotation(position: .trailing, alignment: .leading) {
                Text("\(dim.met)/\(dim.total)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .chartXScale(domain: 0...100)
        .chartXAxis { AxisMarks(values: [0, 50, 100]) }
        .frame(height: CGFloat(dims.count) * 38 + 20)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.bold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func improvementMetric(_ points: Double) -> some View {
        let up = points >= 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                Text("\(up ? "+" : "")\(Int(points)) pts")
            }
            .font(.title2.weight(.bold))
            .foregroundStyle(up ? .green : .red)
            Text("vs. earlier").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Date range sheet

    private var dateRangeSheet: some View {
        NavigationStack {
            Form {
                Section("Generate insights for reports between") {
                    DatePicker("From", selection: $fromDate, displayedComponents: .date)
                    DatePicker("To", selection: $toDate, in: fromDate..., displayedComponents: .date)
                }
                Section {
                    Button {
                        showPicker = false
                        Task { await engine.generate(from: fromDate, to: toDate) }
                    } label: {
                        Text("Generate").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Date range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16))
    }

    /// Default the picker to span from the earliest saved consultation to today.
    private func setDefaultRange() {
        if let earliest = FeedbackStore.shared.records.map(\.date).min() {
            fromDate = earliest
        }
        toDate = Date()
    }
}
