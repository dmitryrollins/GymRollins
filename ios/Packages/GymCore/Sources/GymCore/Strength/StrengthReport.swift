import Foundation

/// The best estimated 1RM for a lift in the window, and where it came from.
public struct LiftEstimate: Equatable, Sendable {
    public let e1RMKg: Double
    public let date: Date
    public let exerciseId: String
}

/// Inputs the report can't do without.
public enum StrengthMissing: String, Equatable, Sendable, CaseIterable {
    /// Sex or birth year not set (or an age the table doesn't cover).
    case profile
    /// No weigh-in yet.
    case bodyweight
}

public struct StrengthRow: Equatable, Sendable, Identifiable {
    public let lift: StrengthLift
    /// Nil when the lift wasn't logged in the window.
    public let estimate: LiftEstimate?
    /// Nil when an input is missing or there's no estimate.
    public let assessment: StrengthAssessment?
    /// The limits note mentions a knee/legs and this lift loads the legs (display only: numbers still show).
    public let paused: Bool

    public var id: String { lift.rawValue }
}

/// Strength levels for the three lifts from the owner's history, bodyweight and profile.
public struct StrengthReport: Equatable, Sendable {
    /// e1RMs from this far back count ("current" strength, not an all-time best).
    public static let windowDays = 365
    /// The table starts at 14 (OpenPowerlifting ages below are rare and not binned).
    public static let minAge = 14

    public let rows: [StrengthRow]
    public let missing: [StrengthMissing]
    public let age: Int?
    public let bodyweightKg: Double?

    public func row(_ lift: StrengthLift) -> StrengthRow? { rows.first { $0.lift == lift } }

    // swiftlint:disable:next function_parameter_count
    public static func make(standards: StrengthStandards, workouts: [Workout], sex: ProfileSex?, birthYear: Int?,
                            bodyweightKg: Double?, limits: String, now: Date, calendar: Calendar) -> StrengthReport {
        let age = birthYear.map { Self.age(birthYear: $0, now: now, calendar: calendar) }
        var missing: [StrengthMissing] = []
        if sex == nil || age.map({ $0 < minAge || standards.ageGroup(age: $0) == nil }) ?? true {
            missing.append(.profile)
        }
        if bodyweightKg == nil { missing.append(.bodyweight) }
        let legsLimited = !LimitedMuscles.from(limits: limits).isEmpty
        let rows = StrengthLift.allCases.map { lift -> StrengthRow in
            let estimate = best(workouts: workouts, lift: lift, now: now)
            var assessment: StrengthAssessment?
            if missing.isEmpty, let estimate, let sex, let age, let bodyweightKg {
                assessment = StrengthLevelCalculator.assess(standards: standards, lift: lift, e1RMKg: estimate.e1RMKg,
                                                            bodyweightKg: bodyweightKg, sex: sex, age: age)
            }
            return StrengthRow(lift: lift, estimate: estimate, assessment: assessment,
                               paused: legsLimited && lift.loadsLegs)
        }
        return StrengthReport(rows: rows, missing: missing, age: age, bodyweightKg: bodyweightKg)
    }

    /// Age this calendar year (birth year only: may be one high before the birthday, like OpenPowerlifting's
    /// year-based ages). Always Gregorian years (what `profiles.birth_year` stores), in `calendar`'s time zone, so a
    /// Buddhist or Japanese device calendar can't shift the age.
    public static func age(birthYear: Int, now: Date, calendar: Calendar) -> Int {
        gregorianYear(now, timeZone: calendar.timeZone) - birthYear
    }

    /// Birth years the profile sheet offers, newest first: ages `minAge`…100 this (Gregorian) year, within
    /// `DomainLimits.birthYear`.
    public static func birthYears(now: Date, calendar: Calendar) -> [Int] {
        let year = gregorianYear(now, timeZone: calendar.timeZone)
        let newest = min(year - minAge, DomainLimits.birthYear.upperBound)
        let oldest = max(year - 100, DomainLimits.birthYear.lowerBound)
        return newest >= oldest ? Array((oldest...newest).reversed()) : []
    }

    private static func gregorianYear(_ date: Date, timeZone: TimeZone) -> Int {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        return gregorian.component(.year, from: date)
    }

    /// Best e1RM (Epley, done non-warm-up sets of 1–12 reps) among the lift's exercises in workouts started in the
    /// last `windowDays` (not in the future). Ties keep the most recent.
    public static func best(workouts: [Workout], lift: StrengthLift, now: Date) -> LiftEstimate? {
        let since = now.addingTimeInterval(-Double(windowDays) * 86_400)
        var best: LiftEstimate?
        for workout in workouts where workout.startedAt >= since && workout.startedAt <= now {
            for entry in workout.entries where lift.exerciseIds.contains(entry.exerciseId) {
                guard let e1RM = WorkoutMetrics.bestE1RM(entry) else { continue }
                if let current = best, e1RM < current.e1RMKg || (e1RM == current.e1RMKg && workout.startedAt <= current.date) {
                    continue
                }
                best = LiftEstimate(e1RMKg: e1RM, date: workout.startedAt, exerciseId: entry.exerciseId)
            }
        }
        return best
    }
}

public enum StrengthGap {
    /// "+17.5 lb" / "+8 kg": the gap rounded UP to 2.5 lb or 0.5 kg, so reaching it always reaches the level.
    public static func text(kg: Double, unit: WeightUnit) -> String {
        let step = unit == .lb ? 2.5 : 0.5
        let value = UnitConverter.fromKg(kg, to: unit)
        let rounded = max(step, ((value / step) - 1e-9).rounded(.up) * step)
        return "+\(WeightFormatter.number(rounded)) \(unit.rawValue)"
    }
}
