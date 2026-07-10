import SwiftUI
import Charts

/// THE unified "progress by skill area" visualization — one component used by
/// the trainee's Insights, the native mentor Cohort tab, and mirrored by the
/// web dashboard (spec published in medadvisor-cloud PLAN.md):
///  • one row per skill area: label · band-colored rounded bar (current
///    score) · % annotation · small trend line (colored by the latest band)
///  • score convention everywhere: met=1, partial=0.5, missed=0, N/A excluded
///  • band colors: ScoreBand (red <40%, orange <75%, green ≥75%)
struct SkillArea: Identifiable {
    struct Point: Identifiable {
        let id = UUID()
        let date: Date?
        let score: Double      // 0...1
        /// Key back to the session (mentor: server sessionId; trainee: record id).
        let sessionKey: String?
        // Raw counts for this dimension in this session — the "/N" companion
        // to the normalized percent.
        let met: Int
        let partial: Int
        let missed: Int
        var applicable: Int { met + partial + missed }
    }
    let id: String
    let label: String
    let current: Double        // 0...1, latest session's score
    let points: [Point]        // chronological, oldest first
    var trend: [Double] { points.map(\.score) }
}

struct SkillAreaChart: View {
    let areas: [SkillArea]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(areas) { area in
                HStack(spacing: 10) {
                    Text(area.label)
                        .font(.caption)
                        .frame(width: 92, alignment: .leading)
                        .lineLimit(2)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule()
                                .fill(ScoreBand.color(area.current))
                                .frame(width: max(8, geo.size.width * area.current))
                        }
                    }
                    .frame(height: 10)
                    Text("\(Int(area.current * 100))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(ScoreBand.color(area.current))
                        .frame(width: 40, alignment: .trailing)
                    if area.trend.count >= 2 {
                        Chart(Array(area.trend.enumerated()), id: \.offset) { point in
                            LineMark(x: .value("Session", point.offset),
                                     y: .value("Score", point.element))
                                .interpolationMethod(.catmullRom)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                        .chartXAxis(.hidden).chartYAxis(.hidden)
                        .chartYScale(domain: 0...1)
                        .foregroundStyle(ScoreBand.color(area.trend.last ?? 0))
                        .frame(width: 56, height: 20)
                    } else {
                        Color.clear.frame(width: 56, height: 20)
                    }
                }
            }
        }
    }
}

/// Builders for the two data sources.
enum SkillAreas {
    private struct DimTally {
        var met = 0, partial = 0, missed = 0
        var score: Double {
            let n = met + partial + missed
            guard n > 0 else { return 0 }
            return (Double(met) + 0.5 * Double(partial)) / Double(n)
        }
    }

    /// Trainee side: build from local records (chronological trends per skill).
    static func from(records: [ConsultationRecord]) -> [SkillArea] {
        let ordered = records.sorted { $0.date < $1.date }
        var trends: [String: [SkillArea.Point]] = [:]
        var labels: [String: String] = [:]
        for record in ordered {
            guard let location = record.location,
                  let rubric = RubricLoader.load(for: location) else { continue }
            var tallies: [String: DimTally] = [:]
            for result in record.feedback.perCriterion where result.status != .notApplicable {
                guard let criterion = rubric.criteria.first(where: { $0.id == result.criterionId })
                else { continue }
                switch result.status {
                case .met:     tallies[criterion.dimension, default: .init()].met += 1
                case .partial: tallies[criterion.dimension, default: .init()].partial += 1
                default:       tallies[criterion.dimension, default: .init()].missed += 1
                }
            }
            for (dimension, tally) in tallies {
                trends[dimension, default: []].append(
                    .init(date: record.date, score: tally.score, sessionKey: record.id,
                          met: tally.met, partial: tally.partial, missed: tally.missed))
                if labels[dimension] == nil {
                    labels[dimension] = rubric.dimensions.first { $0.id == dimension }?.label
                }
            }
        }
        return trends
            .map { SkillArea(id: $0.key,
                             label: labels[$0.key] ?? $0.key,
                             current: $0.value.last?.score ?? 0,
                             points: $0.value) }
            .sorted { $0.label < $1.label }
    }

    /// Mentor side: build from a trainee's shared sessions.
    static func from(sessions: [MentorStore.Session]) -> [SkillArea] {
        let ordered = sessions.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        var trends: [String: [SkillArea.Point]] = [:]
        for session in ordered {
            var tallies: [String: DimTally] = [:]
            for item in session.criteria ?? [] where item.result != "na" {
                switch item.result {
                case "met":     tallies[item.dimension, default: .init()].met += 1
                case "partial": tallies[item.dimension, default: .init()].partial += 1
                default:        tallies[item.dimension, default: .init()].missed += 1
                }
            }
            for (dimension, tally) in tallies {
                trends[dimension, default: []].append(
                    .init(date: session.date, score: tally.score, sessionKey: session.id,
                          met: tally.met, partial: tally.partial, missed: tally.missed))
            }
        }
        let rubric = ordered.last?.rubricId.flatMap { RubricLoader.load(named: $0) }
        return trends
            .map { key, points in
                SkillArea(id: key,
                          label: rubric?.dimensions.first(where: { $0.id == key })?.label ?? key,
                          current: points.last?.score ?? 0,
                          points: points)
            }
            .sorted { $0.label < $1.label }
    }
}

/// Expanded per-skill charts — the "click into the graph" view: one large
/// date-axis chart per skill area; scrub or tap to select a session point,
/// see its score both ways (% and met/partial/missed), and jump to it.
struct SkillAreasDetailView: View {
    let title: String
    let areas: [SkillArea]
    var openSession: ((String) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(areas) { area in
                    AreaDetailCard(area: area, openSession: openSession)
                }
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AreaDetailCard: View {
    let area: SkillArea
    var openSession: ((String) -> Void)?

    @State private var selectedDate: Date?

    private var selectedPoint: SkillArea.Point? {
        guard let selectedDate else { return nil }
        return area.points
            .filter { $0.date != nil }
            .min { abs($0.date!.timeIntervalSince(selectedDate)) < abs($1.date!.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(area.label).font(.subheadline.weight(.bold))
                Spacer()
                Text("\(Int(area.current * 100))%")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(ScoreBand.color(area.current))
            }

            Chart(area.points) { point in
                if let date = point.date {
                    LineMark(x: .value("Date", date),
                             y: .value("Score", point.score * 100))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(ScoreBand.color(area.current))
                    PointMark(x: .value("Date", date),
                              y: .value("Score", point.score * 100))
                        .foregroundStyle(ScoreBand.color(point.score))
                        .symbolSize(selectedPoint?.id == point.id ? 140 : 60)
                    if selectedPoint?.id == point.id {
                        RuleMark(x: .value("Date", date))
                            .foregroundStyle(.tertiary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(values: [0, 50, 100]) }
            .frame(height: 150)

            if let point = selectedPoint {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(point.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                            .font(.caption.weight(.semibold))
                        Text("\(Int(point.score * 100))% · met \(point.met)"
                             + (point.partial > 0 ? " · partial \(point.partial)" : "")
                             + " · missed \(point.missed) of \(point.applicable)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let key = point.sessionKey, let openSession {
                        Button("Open session") { openSession(key) }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text("Scrub or tap the chart to inspect a session · \(area.points.count) session\(area.points.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .glassHairline(16)
    }
}
