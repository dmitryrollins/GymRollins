import Foundation

/// Goal progress and trend from bodyweight entries (kg). Pure; entries in any order.
public struct BodyTrend: Sendable, Equatable {
    public let startKg: Double?
    public let currentKg: Double?
    public let goalKg: Double?
    /// 0…1 of the way from start to goal (clamped).
    public let progress: Double
    /// Least-squares slope over the last 8 weeks, in kg/week (nil with fewer than 2 entries spanning at least 6 days).
    public let weeklyChangeKg: Double?
    /// When the goal is reached at the current slope (nil if not trending toward the goal).
    public let projectedGoalDate: Date?
    /// kg/week needed to reach the goal by the goal date (nil without a goal date or current weight).
    public let requiredWeeklyKg: Double?

    public init(entries: [BodyweightEntry], goalKg: Double?, goalDate: Date?, now: Date) {
        let sorted = entries.sorted { $0.date < $1.date }
        startKg = sorted.first?.weightKg
        currentKg = sorted.last?.weightKg
        self.goalKg = goalKg
        progress = Self.progress(start: startKg, current: currentKg, goal: goalKg)
        let recent = sorted.filter { $0.date >= now.addingTimeInterval(-56 * 86_400) }
        weeklyChangeKg = Self.slopePerWeek(recent)
        projectedGoalDate = Self.projection(current: currentKg, goal: goalKg, slope: weeklyChangeKg, now: now)
        requiredWeeklyKg = Self.required(current: currentKg, goal: goalKg, goalDate: goalDate, now: now)
    }

    static func progress(start: Double?, current: Double?, goal: Double?) -> Double {
        guard let start, let current, let goal, goal != start else { return 0 }
        return min(1, max(0, (current - start) / (goal - start)))
    }

    static func slopePerWeek(_ entries: [BodyweightEntry]) -> Double? {
        guard entries.count >= 2, let first = entries.first?.date, let last = entries.last?.date,
              last.timeIntervalSince(first) >= 6 * 86_400 else { return nil }
        let xs = entries.map { $0.date.timeIntervalSince(first) / (7 * 86_400) }
        let ys = entries.map(\.weightKg)
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        let num = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let den = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        return den == 0 ? nil : num / den
    }

    static func projection(current: Double?, goal: Double?, slope: Double?, now: Date) -> Date? {
        guard let current, let goal, let slope, slope != 0 else { return nil }
        let weeks = (goal - current) / slope
        guard weeks > 0 else { return nil }
        return now.addingTimeInterval(weeks * 7 * 86_400)
    }

    static func required(current: Double?, goal: Double?, goalDate: Date?, now: Date) -> Double? {
        guard let current, let goal, let goalDate else { return nil }
        let weeks = goalDate.timeIntervalSince(now) / (7 * 86_400)
        return weeks > 0 ? (goal - current) / weeks : nil
    }
}
