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
    /// Per-session, per-dimension score: met=1, partial=0.5, missed=0, N/A
    /// excluded — the shared convention.
    private static func dimensionScores(results: [CriterionResult],
                                        rubric: Rubric) -> [String: Double] {
        var buckets: [String: [Double]] = [:]
        for result in results where result.status != .notApplicable {
            guard let criterion = rubric.criteria.first(where: { $0.id == result.criterionId })
            else { continue }
            let value: Double = result.status == .met ? 1 : (result.status == .partial ? 0.5 : 0)
            buckets[criterion.dimension, default: []].append(value)
        }
        return buckets.mapValues { $0.reduce(0, +) / Double($0.count) }
    }

    /// Trainee side: build from local records (chronological trends per skill).
    static func from(records: [ConsultationRecord]) -> [SkillArea] {
        let ordered = records.sorted { $0.date < $1.date }
        var trends: [String: [SkillArea.Point]] = [:]
        var labels: [String: String] = [:]
        for record in ordered {
            guard let location = record.location,
                  let rubric = RubricLoader.load(for: location) else { continue }
            for (dimension, score) in dimensionScores(results: record.feedback.perCriterion,
                                                      rubric: rubric) {
                trends[dimension, default: []].append(.init(date: record.date, score: score))
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
            for (dimension, score) in session.dimensionScores {
                trends[dimension, default: []].append(.init(date: session.date, score: score))
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
/// date-axis chart per skill area, band-colored line + session points.
struct SkillAreasDetailView: View {
    let title: String
    let areas: [SkillArea]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(areas) { area in
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
                            }
                        }
                        .chartYScale(domain: 0...100)
                        .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                        .frame(height: 150)
                        Text("\(area.points.count) session\(area.points.count == 1 ? "" : "s")")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .glassHairline(16)
                }
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
