import Foundation
import GymCore

/// Every string the activity screens show (plan 39):
/// - outside workouts in the Log and their detail;
/// - the measured line on a GymRollins workout;
/// - the week's measured calories;
/// - Today's days of activity.
enum ActivityText {
    static func title(_ activity: HealthActivity) -> String { OutsideWorkoutKind(slug: activity.kind).title }

    static func symbol(_ activity: HealthActivity) -> String { OutsideWorkoutKind(slug: activity.kind).symbol }

    /// "Fri 25 Sep · 45 min" (active time).
    static func dateAndDuration(_ activity: HealthActivity) -> String {
        let date = activity.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(date) \u{00B7} \(DurationFormatter.hoursMinutes(activity.durationS))"
    }

    /// "3.4 km", or "2.1 mi" for a profile in lb (the distance unit of cardio sets); nil without a distance.
    static func distance(_ activity: HealthActivity, unit: WeightUnit) -> String? {
        guard let meters = activity.distanceM, meters > 0 else { return nil }
        let value = WeightFormatter.number(meters / SetFieldFormat.metersPerDistanceUnit(unit))
        return "\(value) \(SetFieldFormat.distanceUnit(unit))"
    }

    /// "3.4 km · 180 kcal · Apple Watch": what Health measured, then where it came from.
    static func facts(_ activity: HealthActivity, unit: WeightUnit) -> String {
        [distance(activity, unit: unit), activity.kcal.map(kcalText), activity.sourceName]
            .compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// "Apple Watch measured 412 kcal · avg 128 bpm · max 162 bpm", under a GymRollins workout's calories; nil when
    /// nothing was measured.
    static func measuredLine(_ activity: HealthActivity) -> String? {
        let parts = [activity.kcal.map(kcalText), activity.avgHr.map { "avg \($0) bpm" },
                     activity.maxHr.map { "max \($0) bpm" }].compactMap { $0 }
        return parts.isEmpty ? nil : "\(activity.sourceName) measured " + parts.joined(separator: " \u{00B7} ")
    }

    /// The measured kcal of the `shown` outside workouts that started in the ISO week (Mon–Sun) containing `date`: the
    /// week `CalorieService.weekTotal` sums.
    static func weekKcal(_ shown: [HealthActivity], containing date: Date,
                         calendar: Calendar = Calendar(identifier: .iso8601)) -> Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return 0 }
        return Int(shown.filter { week.contains($0.startedAt) }.compactMap(\.kcal).reduce(0, +).rounded())
    }

    /// "+ 640 kcal from other activities (measured)": under the week's estimate and never added to it (decision 10).
    static func otherKcalLine(_ kcal: Int) -> String { "+ \(kcal.formatted()) kcal from other activities (measured)" }

    /// Today's Activity row: "4,210 steps · 210 kcal · 18 min exercise", zeros before today's first data.
    static func todayLine(_ day: ActivityDay?) -> String {
        let move = Int((day?.moveKcal ?? 0).rounded())
        return "\((day?.steps ?? 0).formatted()) steps \u{00B7} \(move.formatted()) kcal \u{00B7} "
            + "\(day?.exerciseMin ?? 0) min exercise"
    }

    /// A day in the 7-day sheet: today's line, then the stand hours when an Apple Watch counted them.
    static func dayLine(_ day: ActivityDay) -> String {
        todayLine(day) + (day.standH.map { " \u{00B7} \($0) h stand" } ?? "")
    }

    private static func kcalText(_ value: Double) -> String { "\(Int(value.rounded()).formatted()) kcal" }
}
