import Foundation
import GymCore

/// Every string and metric the activity screens show (plan 39, in Apple Fitness' look §4.1):
/// - outside workouts in the Log and their detail;
/// - what Health measured during a GymRollins workout;
/// - the week's measured calories;
/// - Today's days of activity.
enum ActivityText {
    static func title(_ activity: HealthActivity) -> String { OutsideWorkoutKind(slug: activity.kind).title }

    static func symbol(_ activity: HealthActivity) -> String { OutsideWorkoutKind(slug: activity.kind).symbol }

    // MARK: Outside workouts

    /// The detail's "Workout Details", in Fitness' order: Workout Time, Distance, Active and Total Calories, Avg. Power
    /// and Cadence, Avg. and Max Heart Rate. A value Health didn't measure is left out.
    static func details(_ activity: HealthActivity, unit: WeightUnit) -> [MetricReading] {
        [time(activity), distance(activity, unit: unit), activeKcal(activity),
         activity.totalKcal.map { kcal("totalKcal", "Total Calories", $0, tint: .calories) },
         activity.avgPowerW.map { power($0) },
         activity.avgCadenceRpm.map {
             MetricReading(key: "cadence", label: "Avg. Cadence", value: "\($0)", unit: "RPM",
                           spoken: "\($0) revolutions per minute", tint: .cadence)
         },
         activity.avgHr.map { heartRate("avgHr", "Avg. Heart Rate", $0) },
         activity.maxHr.map { heartRate("maxHr", "Max Heart Rate", $0) }].compactMap { $0 }
    }

    /// The big number under the title and on the Log card, in `workout` colour: the distance, else the active
    /// calories, else the time.
    static func headline(_ activity: HealthActivity, unit: WeightUnit) -> MetricReading {
        let reading = distance(activity, unit: unit) ?? activeKcal(activity) ?? time(activity)
        return MetricReading(key: reading.key, label: reading.label, value: reading.value, unit: reading.unit,
                             spoken: reading.spoken, tint: .workout)
    }

    /// "45 min · Apple Watch", under the Log card's date.
    static func durationAndSource(_ activity: HealthActivity) -> String {
        "\(DurationFormatter.hoursMinutes(activity.durationS)) \u{00B7} \(activity.sourceName)"
    }

    /// "Fri 25 Sep", the Log card's date.
    static func shortDate(_ activity: HealthActivity) -> String {
        activity.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// The Log card for VoiceOver: "Walk, 3.40 kilometres, Fri 25 Sep, 45 min, Apple Watch".
    static func cardLabel(_ activity: HealthActivity, unit: WeightUnit) -> String {
        [title(activity), headline(activity, unit: unit).spoken, shortDate(activity),
         DurationFormatter.hoursMinutes(activity.durationS), activity.sourceName].joined(separator: ", ")
    }

    /// "November 15, 2026, 16:02–16:07", under the detail's headline.
    static func dateAndTimes(_ activity: HealthActivity) -> String {
        let day = activity.startedAt.formatted(date: .long, time: .omitted)
        let from = activity.startedAt.formatted(date: .omitted, time: .shortened)
        let to = activity.endedAt.formatted(date: .omitted, time: .shortened)
        return "\(day), \(from)\u{2013}\(to)"
    }

    // MARK: A GymRollins workout

    /// What Health measured during a GymRollins workout: Active Calories, Avg. and Max Heart Rate, and Avg. Power when
    /// there is one. Empty when nothing was measured.
    static func measured(_ activity: HealthActivity) -> [MetricReading] {
        [activeKcal(activity), activity.avgHr.map { heartRate("avgHr", "Avg. Heart Rate", $0) },
         activity.maxHr.map { heartRate("maxHr", "Max Heart Rate", $0) }, activity.avgPowerW.map { power($0) }]
            .compactMap { $0 }
    }

    /// "Apple Watch measured", over those values.
    static func measuredTitle(_ activity: HealthActivity) -> String { "\(activity.sourceName) measured" }

    // MARK: The week

    /// The measured kcal of the `shown` outside workouts that started in the ISO week (Mon–Sun) containing `date`: the
    /// week `CalorieService.weekTotal` sums.
    static func weekKcal(_ shown: [HealthActivity], containing date: Date,
                         calendar: Calendar = Calendar(identifier: .iso8601)) -> Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return 0 }
        return Int(shown.filter { week.contains($0.startedAt) }.compactMap(\.kcal).reduce(0, +).rounded())
    }

    /// "+ 640 kcal from other activities (measured)": under the week's estimate and never added to it (decision 10).
    static func otherKcalLine(_ kcal: Int) -> String { "+ \(kcal.formatted()) kcal from other activities (measured)" }

    // MARK: Days of activity

    /// Today's Activity row and a day of the 7-day sheet: Steps, Move, Exercise, then Stand when an Apple Watch counted
    /// it. Zeros before today's first data.
    static func dayMetrics(_ day: ActivityDay?) -> [MetricReading] {
        let steps = (day?.steps ?? 0).formatted()
        let move = Int((day?.moveKcal ?? 0).rounded())
        let exercise = day?.exerciseMin ?? 0
        return [MetricReading(key: "steps", label: "Steps", value: steps, unit: nil, spoken: steps, tint: .steps),
                kcal("move", "Move", Double(move), tint: .calories),
                MetricReading(key: "exercise", label: "Exercise", value: "\(exercise)", unit: "MIN",
                              spoken: counted(exercise, "minute"), tint: .exercise),
                day?.standH.map {
                    MetricReading(key: "stand", label: "Stand", value: "\($0)", unit: "HRS",
                                  spoken: counted($0, "hour"), tint: .stand)
                }].compactMap { $0 }
    }

    /// "Steps 4,210, Move 210 kilocalories, Exercise 18 minutes": a row of metrics read as one element.
    static func spokenSummary(_ readings: [MetricReading]) -> String {
        readings.map { "\($0.label) \($0.spoken)" }.joined(separator: ", ")
    }

    // MARK: Values

    /// Workout time as Fitness shows it, always with hours: "0:05:08", "1:02:05".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%ld:%02ld:%02ld", total / 3_600, (total % 3_600) / 60, total % 60)
    }

    /// The same time for VoiceOver: "1 hour 2 minutes 5 seconds", "5 minutes 8 seconds", "0 seconds".
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let parts = [(total / 3_600, "hour"), ((total % 3_600) / 60, "minute"), (total % 60, "second")]
            .filter { $0.0 > 0 }.map { counted($0.0, $0.1) }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }

    private static func time(_ activity: HealthActivity) -> MetricReading {
        MetricReading(key: "duration", label: "Workout Time", value: clock(activity.durationS), unit: nil,
                      spoken: spokenDuration(activity.durationS), tint: .time)
    }

    /// Two decimals, as Fitness shows it, in the profile's unit ("2.26 KM", or "1.40 MI" for a profile in lb, the
    /// distance unit of cardio sets); nil without a distance.
    private static func distance(_ activity: HealthActivity, unit: WeightUnit) -> MetricReading? {
        guard let meters = activity.distanceM, meters > 0 else { return nil }
        let value = String(format: "%.2f", meters / SetFieldFormat.metersPerDistanceUnit(unit))
        return MetricReading(key: "distance", label: "Distance", value: value,
                             unit: SetFieldFormat.distanceUnit(unit).uppercased(),
                             spoken: "\(value) \(unit == .lb ? "miles" : "kilometres")", tint: .distance)
    }

    private static func activeKcal(_ activity: HealthActivity) -> MetricReading? {
        activity.kcal.map { kcal("kcal", "Active Calories", $0, tint: .calories) }
    }

    private static func kcal(_ key: String, _ label: String, _ value: Double, tint: MetricTint) -> MetricReading {
        let whole = Int(value.rounded())
        return MetricReading(key: key, label: label, value: whole.formatted(), unit: "KCAL",
                             spoken: "\(whole.formatted()) kilocalorie\(whole == 1 ? "" : "s")", tint: tint)
    }

    private static func power(_ watts: Int) -> MetricReading {
        MetricReading(key: "power", label: "Avg. Power", value: "\(watts)", unit: "W",
                      spoken: "\(watts) watt\(watts == 1 ? "" : "s")", tint: .power)
    }

    private static func heartRate(_ key: String, _ label: String, _ bpm: Int) -> MetricReading {
        MetricReading(key: key, label: label, value: "\(bpm)", unit: "BPM", spoken: "\(bpm) beats per minute",
                      tint: .heartRate)
    }

    /// "1 minute", "18 minutes".
    private static func counted(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : "s")" }
}
