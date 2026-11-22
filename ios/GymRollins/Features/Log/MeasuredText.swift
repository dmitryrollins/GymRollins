import Foundation
import GymCore
import GymHealth

/// What recorded a workout, under its date: "Apple Watch" with the watch symbol, say.
struct RecordedBy: Equatable {
    let text: String
    let symbol: String
}

/// Whether a workout is in Apple Health (plan 15), as the detail's footnote and the Summary's calorie card say it.
enum HealthSaveLine: Equatable {
    case saving, saved, failed

    var text: String {
        switch self {
        case .saving: "Saving to Apple Health\u{2026}"
        case .saved: "Saved to Apple Health"
        case .failed: "Couldn't save to Apple Health"
        }
    }

    var symbol: String {
        switch self {
        case .saving: "heart"
        case .saved: "heart.fill"
        case .failed: "exclamationmark.triangle"
        }
    }
}

/// Every string and metric a GymRollins workout's detail shows (plan 40, spec §4), in Apple Fitness' look: the headline
/// and date line, what recorded it, "Workout Details" and its footnote, "Effort", the heart-rate charts, "Strength", and
/// what each set row says. VoiceOver gets each value with its unit in full, and each chart as one summary.
enum MeasuredText {
    // MARK: Header

    /// The workout time under the title, as the Log card shows it ("58:20"), in `workout` colour.
    static func headline(_ summary: MeasuredSummary) -> MetricReading {
        MetricReading(key: "headline", label: "Workout Time", value: DurationFormatter.clock(summary.workoutTime),
                      unit: nil, spoken: ActivityText.spokenDuration(summary.workoutTime), tint: .workout)
    }

    /// "Sat 19 Sep 2026, 18:00–18:58", in the phone's language and time zone.
    static func dateAndTimes(start: Date, end: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let day = Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.abbreviated).day().month(.abbreviated)
            .year()
        return "\(start.formatted(day)), \(time(start, locale: locale, timeZone: timeZone))\u{2013}"
            + time(end, locale: locale, timeZone: timeZone)
    }

    /// The GymRollins watch app, the attached recording's app, or this iPhone for a workout logged here that Health
    /// measured nothing for. Nil for an import or an agent's workout: nothing on this phone recorded it.
    static func recordedBy(_ source: MeasuredSummary.Source, loggedHere: Bool) -> RecordedBy? {
        switch source {
        case .watch: RecordedBy(text: "Apple Watch", symbol: "applewatch")
        case .attached(let sourceName): RecordedBy(text: sourceName, symbol: "heart.text.square")
        case .estimate: loggedHere ? RecordedBy(text: "iPhone", symbol: "iphone") : nil
        }
    }

    // MARK: Workout Details

    /// Fitness' order: Workout Time, Active and Total Calories, Avg. and Max Heart Rate. With nothing measured the
    /// estimate takes the calories' place and Total Calories is left out; heart rate shows whenever Health has it.
    static func details(_ summary: MeasuredSummary, usedDefaultBodyWeight: Bool,
                        locale: Locale = .current) -> [MetricReading] {
        let time = MetricReading(key: "workoutTime", label: "Workout Time", value: ActivityText.clock(summary.workoutTime),
                                 unit: nil, spoken: ActivityText.spokenDuration(summary.workoutTime), tint: .time)
        let calories: [MetricReading?] = summary.source == .estimate
            ? [summary.estimatedKcal.map { estimate($0, usedDefaultBodyWeight: usedDefaultBodyWeight, locale: locale) }]
            : [summary.activeKcal.map { ActivityText.kcal("activeKcal", "Active Calories", $0, tint: .calories) },
               summary.totalKcal.map { ActivityText.kcal("totalKcal", "Total Calories", $0, tint: .calories) }]
        let heart = [summary.avgHr.map { ActivityText.heartRate("avgHeartRate", "Avg. Heart Rate", $0) },
                     summary.maxHr.map { ActivityText.heartRate("maxHeartRate", "Max Heart Rate", $0) }]
        return [time] + (calories + heart).compactMap { $0 }
    }

    /// "Calories (estimated)" over "≈ 277KCAL", the Compendium estimate (plan 15); "(estimated, 70 kg)" without a
    /// weigh-in, as the calorie card said it.
    static func estimate(_ kcal: Int, usedDefaultBodyWeight: Bool, locale: Locale = .current) -> MetricReading {
        let value = kcal.formatted(.number.locale(locale))
        return MetricReading(key: "kcal",
                             label: usedDefaultBodyWeight ? "Calories (estimated, 70 kg)" : "Calories (estimated)",
                             value: "\u{2248} \(value)", unit: "KCAL",
                             spoken: "about \(value) kilocalorie\(kcal == 1 ? "" : "s")", tint: .calories)
    }

    /// The footnote's first part: what measured the grid.
    static func measuredBy(_ source: MeasuredSummary.Source) -> String {
        switch source {
        case .watch: "Measured by Apple Watch"
        case .attached(let sourceName): "Measured by \(sourceName)"
        case .estimate: "Estimated from your sets and body weight"
        }
    }

    /// The footnote's second part: today's Apple Health save status; nil while Health is off or the workout isn't one
    /// Health gets.
    static func healthSave(_ status: HealthSync.ExportStatus) -> HealthSaveLine? {
        switch status {
        case .notEnabled, .notEligible: nil
        case .pending: .saving
        case .saved: .saved
        case .failed: .failed
        }
    }

    // MARK: Strength

    /// Exercises, working sets done and volume in plain text, records in amber when there is one.
    static func strength(_ workout: Workout, records: Int, locale: Locale = .current) -> [MetricReading] {
        [count("exercises", "Exercises", workout.entries.count, noun: "exercise", locale: locale),
         count("sets", "Sets", WorkoutMetrics.workingSetCount(workout), noun: "set", locale: locale),
         volume(WorkoutMetrics.volumeKg(workout), locale: locale),
         MetricReading(key: "records", label: "Records", value: records.formatted(.number.locale(locale)), unit: nil,
                       spoken: counted(records, "record", locale: locale), tint: records > 0 ? .record : .primary)]
    }

    /// "885KG", or from a tonne "1.8T" ("1,8T" where the language writes a comma): kilograms whatever the profile's
    /// unit, as the detail showed it before.
    static func volume(_ kg: Double, locale: Locale = .current) -> MetricReading {
        guard kg >= 1_000 else {
            let value = WeightFormatter.number(kg)
            return MetricReading(key: "volume", label: "Volume", value: value, unit: "KG", spoken: "\(value) kilograms",
                                 tint: .primary)
        }
        let tonnes = (kg / 1_000).formatted(.number.precision(.fractionLength(1)).locale(locale))
        return MetricReading(key: "volume", label: "Volume", value: tonnes, unit: "T", spoken: "\(tonnes) tonnes",
                             tint: .primary)
    }

    // MARK: Sets

    /// What VoiceOver says for a set row in Exercises: "Set 1, 10 reps, 130 pounds, 2 reps left", or "Warm-up, 8 reps,
    /// 44 pounds". A bodyweight set leaves its weight out, as `WorkoutText` does; "reps left" only for a rated set.
    static func spokenSet(_ set: WorkoutSet, position: Int, mode: ExerciseMode, unit: WeightUnit) -> String {
        let name = set.warmup ? "Warm-up" : "Set \(position.formatted())"
        let repsLeft = SetEffort.canRate(set, mode: mode)
            ? SetEffort.choice(for: set.rir).map(SetEffortText.accessibilityLabel) : nil
        return ([name] + spokenAmounts(set, mode: mode, unit: unit) + [repsLeft].compactMap { $0 })
            .joined(separator: ", ")
    }

    /// "10 reps, 130 pounds", "30 seconds", "20 minutes, 3.2 kilometres": the set's own numbers, as its row shows them.
    private static func spokenAmounts(_ set: WorkoutSet, mode: ExerciseMode, unit: WeightUnit) -> [String] {
        switch mode {
        case .reps:
            let reps = counted(set.reps, "rep", locale: .current)
            guard abs(set.weightKg) >= 0.01 else { return [reps] }
            let weight = WeightFormatter.number(kg: set.weightKg, lb: set.weightLb, unit: unit)
            return [reps, amount(weight, unit == .lb ? "pound" : "kilogram")]
        case .time:
            return [ActivityText.spokenDuration(TimeInterval(set.sec ?? 0))]
        case .cardio:
            let minutes = SetFieldFormat.display(.minutes(set.id), set: set, unit: unit)
            let distance = SetFieldFormat.display(.distance(set.id), set: set, unit: unit)
            let distanceUnit = unit == .lb ? "mile" : "kilometre"
            return [amount(minutes, "minute")] + (distance.isEmpty ? [] : [amount(distance, distanceUnit)])
        }
    }

    // MARK: Effort

    /// "6 Moderate", or "5 Moderate · Estimated" for the Apple Watch's estimate.
    static func effort(_ effort: Effort, locale: Locale = .current) -> String {
        let value = "\(effort.score.formatted(.number.locale(locale))) \(effort.level.title)"
        return effort.estimated ? "\(value) \u{00B7} Estimated" : value
    }

    /// The same for VoiceOver: "6 out of 10, Moderate", "5 out of 10, Moderate, estimated".
    static func spokenEffort(_ effort: Effort, locale: Locale = .current) -> String {
        let value = "\(outOfTen(effort.score, locale: locale)), \(effort.level.title)"
        return effort.estimated ? "\(value), estimated" : value
    }

    /// A score on the Effort sheet's scale for VoiceOver: "6, Moderate".
    static func spokenScore(_ score: Int, locale: Locale = .current) -> String {
        "\(score.formatted(.number.locale(locale))), \(effortWord(score) ?? "")"
    }

    /// The scale's word for a score (Apple's: Easy 1–3, Moderate 4–6, Hard 7–8, All Out 9–10); nil outside 1–10.
    static func effortWord(_ score: Int) -> String? { WorkoutEffortLevel.level(for: score)?.title }

    /// The Effort sheet's key under the scale: "1–3 Easy · 4–6 Moderate · 7–8 Hard · 9–10 All Out".
    static func effortKey(locale: Locale = .current) -> String {
        WorkoutEffortLevel.allCases.compactMap { level -> String? in
            let scores = Effort.range.filter { WorkoutEffortLevel.level(for: $0) == level }
            guard let first = scores.first, let last = scores.last else { return nil }
            let number = IntegerFormatStyle<Int>.number.locale(locale)
            return "\(first.formatted(number))\u{2013}\(last.formatted(number)) \(level.title)"
        }.joined(separator: " \u{00B7} ")
    }

    /// Under the Effort card when Health is on and allowed but didn't take the rating: the detail footnote's words.
    static let effortNotInHealth = HealthSaveLine.failed.text

    /// Beside the Allow pill, while the effort types were never asked for (Health turned on before build 5).
    static let effortAllowNote = "Read and save effort in Apple Health."

    /// "6 out of 10".
    private static func outOfTen(_ score: Int, locale: Locale) -> String {
        let number = IntegerFormatStyle<Int>.number.locale(locale)
        return "\(score.formatted(number)) out of \(Effort.range.upperBound.formatted(number))"
    }

    // MARK: Heart rate charts

    /// The Heart Rate chart's three time labels ("18:00", "18:29", "18:58"); the post-workout chart's are its end time,
    /// then "1 MIN" and "2 MIN", as Fitness labels it.
    static func tickLabels(_ data: HeartRateChartData, postWorkout: Bool, locale: Locale = .current,
                           timeZone: TimeZone = .current) -> [String] {
        data.ticks.enumerated().map { index, tick in
            postWorkout && index > 0
                ? "\(index.formatted(.number.locale(locale))) MIN"
                : time(tick, locale: locale, timeZone: timeZone)
        }
    }

    /// "128 BPM AVG", the Heart Rate chart's caption; nil without readings.
    static func averageCaption(_ data: HeartRateChartData, locale: Locale = .current) -> String? {
        data.avgBpm.map { "\($0.formatted(.number.locale(locale))) BPM AVG" }
    }

    /// "162", the Heart Rate chart's maximum at its top right; nil without readings.
    static func maximumLabel(_ data: HeartRateChartData, locale: Locale = .current) -> String? {
        data.maxBpm.map { $0.formatted(.number.locale(locale)) }
    }

    /// "124 BPM", the Post-Workout Heart Rate chart's caption: its last reading.
    static func lastReadingCaption(_ bpm: Int, locale: Locale = .current) -> String {
        "\(bpm.formatted(.number.locale(locale))) BPM"
    }

    /// The Heart Rate chart for VoiceOver (spec §4): "Heart rate 18:00 to 18:58: average 128, maximum 162".
    static func chartSummary(_ data: HeartRateChartData, locale: Locale = .current,
                             timeZone: TimeZone = .current) -> String {
        let span = chartSpan(data, locale: locale, timeZone: timeZone)
        guard let avg = data.avgBpm, let max = data.maxBpm else { return "Heart rate \(span): no readings" }
        let number = IntegerFormatStyle<Int>.number.locale(locale)
        return "Heart rate \(span): average \(avg.formatted(number)), maximum \(max.formatted(number))"
    }

    /// The post-workout chart for VoiceOver: "Heart rate after the workout, 18:58 to 19:01: last reading 124".
    static func postChartSummary(_ data: HeartRateChartData, last: Int, locale: Locale = .current,
                                 timeZone: TimeZone = .current) -> String {
        "Heart rate after the workout, \(chartSpan(data, locale: locale, timeZone: timeZone)): last reading "
            + last.formatted(.number.locale(locale))
    }

    /// The audio graph's x value: "29 minutes in", "1 minute in".
    static func spokenMinutesIn(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        "\(counted(Int(max(0, seconds) / 60), "minute", locale: locale)) in"
    }

    /// The audio graph's y value, to the nearest beat: "128 beats per minute".
    static func spokenBpm(_ bpm: Double, locale: Locale = .current) -> String {
        "\(Int(bpm.rounded()).formatted(.number.locale(locale))) beats per minute"
    }

    /// "18:00 to 18:58".
    private static func chartSpan(_ data: HeartRateChartData, locale: Locale, timeZone: TimeZone) -> String {
        "\(time(data.start, locale: locale, timeZone: timeZone)) to \(time(data.end, locale: locale, timeZone: timeZone))"
    }

    // MARK: Values

    private static func count(_ key: String, _ label: String, _ value: Int, noun: String,
                              locale: Locale) -> MetricReading {
        MetricReading(key: key, label: label, value: value.formatted(.number.locale(locale)), unit: nil,
                      spoken: counted(value, noun, locale: locale), tint: .primary)
    }

    /// "1 record", "3 sets".
    private static func counted(_ value: Int, _ noun: String, locale: Locale) -> String {
        "\(value.formatted(.number.locale(locale))) \(noun)\(value == 1 ? "" : "s")"
    }

    /// "1 pound", "130 pounds", "2.5 minutes": a number already written as the row shows it.
    private static func amount(_ number: String, _ noun: String) -> String {
        "\(number) \(noun)\(number == "1" ? "" : "s")"
    }

    /// "18:00" in the phone's 12- or 24-hour style.
    private static func time(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
    }
}
