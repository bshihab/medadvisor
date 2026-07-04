import SwiftUI

/// Shared scoring visuals so the History list, Feedback screen, and Insights
/// all show the same colors, bands, and proportion bar.
enum ScoreBand {
    static func label(_ metFraction: Double) -> String {
        switch metFraction {
        case ..<0.4:  return "Emerging"
        case ..<0.75: return "Developing"
        default:      return "Proficient"
        }
    }
    static func color(_ metFraction: Double) -> Color {
        switch metFraction {
        case ..<0.4:  return .red
        case ..<0.75: return .orange
        default:      return .green
        }
    }
}

extension ConsultationFeedback {
    var metCount: Int { perCriterion.filter { $0.status == .met }.count }
    var partialCount: Int { perCriterion.filter { $0.status == .partial }.count }
    var missedCount: Int { perCriterion.filter { $0.status == .missed }.count }
    var naCount: Int { perCriterion.filter { $0.status == .notApplicable }.count }
    /// Applicable criteria only — N/A (e.g. no exam) is excluded so an absent
    /// exam doesn't count against the score (12/16 → 12/15).
    var total: Int { perCriterion.filter { $0.status != .notApplicable }.count }
    var metFraction: Double { total == 0 ? 0 : Double(metCount) / Double(total) }
}

/// A thin stacked proportion bar: met (green) / partial (orange) / missed (red).
struct ScoreBar: View {
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
