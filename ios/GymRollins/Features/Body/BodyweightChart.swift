import Charts
import GymData
import SwiftUI

/// Chart range filters for the Body tab's bodyweight chart.
enum ChartRange: String, CaseIterable, Identifiable {
    case week = "Week", month = "Month", sixMonths = "6 Months", year = "Year"

    var id: String { rawValue }

    var days: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .sixMonths: 182
        case .year: 365
        }
    }
}

/// Line + point chart of bodyweight entries (always kg), with a dashed rule at the goal weight.
struct BodyweightChart: View {
    let entries: [BodyweightEntry]
    let goalKg: Double?

    var body: some View {
        Chart {
            ForEach(entries) { entry in
                LineMark(x: .value("Date", entry.date), y: .value("Weight", entry.weightKg))
                PointMark(x: .value("Date", entry.date), y: .value("Weight", entry.weightKg))
            }
            if let goalKg {
                RuleMark(y: .value("Goal", goalKg))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .foregroundStyle(Theme.accent)
        .chartYScale(domain: BodyweightChartDomain.yDomain(entries: entries, goalKg: goalKg))
    }
}

/// Pure y-axis domain for the bodyweight chart: tight around the data and goal line (padded by
/// 1 kg, rounded outward to the nearest 0.5 kg) so a small trend like 81 → 81.8 kg and a distant
/// goal line like 85 kg both read clearly, instead of Swift Charts' default auto-scaled axis.
enum BodyweightChartDomain {
    static func yDomain(entries: [BodyweightEntry], goalKg: Double?) -> ClosedRange<Double> {
        var values = entries.map(\.weightKg)
        if let goalKg { values.append(goalKg) }
        guard let minValue = values.min(), let maxValue = values.max() else { return 0...1 }
        let lower = niceRound(minValue - 1, .down)
        let upper = niceRound(maxValue + 1, .up)
        return lower < upper ? lower...upper : lower...(lower + 1)
    }

    /// Rounds to the nearest 0.5, outward in `rule`'s direction so the padding is never clipped.
    private static func niceRound(_ value: Double, _ rule: FloatingPointRoundingRule) -> Double {
        (value * 2).rounded(rule) / 2
    }
}
