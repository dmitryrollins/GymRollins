import Foundation
import GymCore

/// One editable box on the logging screen. The screen owns a single `@FocusState` of this type
/// and a draft-text dictionary keyed by it, so focus and in-progress text never live in (and never
/// get reset with) individual rows.
enum SetField: Hashable {
    case reps(UUID)
    case weight(UUID)
    case sec(UUID)
    case minutes(UUID)
    case distance(UUID)

    var setId: UUID {
        switch self {
        case .reps(let id), .weight(let id), .sec(let id), .minutes(let id), .distance(let id): id
        }
    }

    /// Suffix of the `logging.set.<index>.<suffix>` accessibility identifier.
    var identifierSuffix: String {
        switch self {
        case .reps: "reps"
        case .weight: "weight"
        case .sec: "sec"
        case .minutes: "minutes"
        case .distance: "distance"
        }
    }
}

/// Pure display/parse rules for set fields. Parsing only ever happens for text the user edited:
/// text equal to the current display string maps back to the unchanged set, so viewing a set
/// (with its rounded display) can never rewrite the stored load.
enum SetFieldFormat {
    static let metersPerMile = 1_609.344

    /// The exercise's mode, except that a rep-mode exercise whose sets carry no reps but a duration (or distance)
    /// follows the data: Fitbod's timed Plank / Single Leg Glute Bridge map to rep-mode library entries, and their
    /// imported sets must still show and edit as time (or cardio) rather than "0 × 0".
    static func mode(exercise: Exercise?, sets: [WorkoutSet]) -> ExerciseMode {
        if let exercise, exercise.mode != .reps { return exercise.mode }
        if let shape = dataMode(sets) { return shape }
        if exercise != nil { return .reps }
        return sets.contains { $0.sec != nil } ? .time : .reps
    }

    /// `.cardio`/`.time` when no set has reps and some set has a distance/duration; nil otherwise.
    private static func dataMode(_ sets: [WorkoutSet]) -> ExerciseMode? {
        guard !sets.contains(where: { $0.reps > 0 }) else { return nil }
        if sets.contains(where: { $0.distanceM != nil || $0.minutes != nil }) { return .cardio }
        if sets.contains(where: { $0.sec != nil }) { return .time }
        return nil
    }

    static func fields(for mode: ExerciseMode, setId: UUID) -> [SetField] {
        switch mode {
        case .reps: [.reps(setId), .weight(setId)]
        case .time: [.sec(setId), .weight(setId)]
        case .cardio: [.minutes(setId), .distance(setId)]
        }
    }

    static func label(_ field: SetField, warmup: Bool, unit: WeightUnit) -> String {
        switch field {
        case .reps: warmup ? "Warm-up Reps" : "Reps"
        case .weight: "Weight (\(unit.rawValue))"
        case .sec: "Seconds"
        case .minutes: "Minutes"
        case .distance: "Distance (\(distanceUnit(unit)))"
        }
    }

    static func isDecimal(_ field: SetField) -> Bool {
        switch field {
        case .reps, .sec: false
        case .weight, .minutes, .distance: true
        }
    }

    static func display(_ field: SetField, set: WorkoutSet, unit: WeightUnit) -> String {
        switch field {
        case .reps: return "\(set.reps)"
        case .weight: return WeightFormatter.number(UnitConverter.fromKg(set.weightKg, to: unit))
        case .sec: return set.sec.map(String.init) ?? ""
        case .minutes:
            let minutes = set.minutes ?? set.sec.map { Double($0) / 60 }
            return minutes.map(WeightFormatter.number) ?? ""
        case .distance:
            return set.distanceM.map { WeightFormatter.number($0 / metersPerDistanceUnit(unit)) } ?? ""
        }
    }

    /// The set with `text` applied to `field`, or nil when the text is invalid or outside `DomainLimits` (caller
    /// reverts it).
    static func applying(_ text: String, to field: SetField, set: WorkoutSet, unit: WeightUnit) -> WorkoutSet? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == display(field, set: set, unit: unit) { return set }
        switch field {
        case .reps:
            return Int(trimmed).flatMap {
                DomainLimits.setReps.contains($0) ? set.with(weightKg: set.weightKg, reps: $0) : nil
            }
        case .sec:
            return Int(trimmed).flatMap { DomainLimits.setSeconds.contains($0) ? set.with(sec: $0) : nil }
        case .weight:
            return decimal(trimmed).map { UnitConverter.toKg($0, from: unit) }
                .flatMap { DomainLimits.setWeightKg.contains($0) ? set.with(weightKg: $0, reps: set.reps) : nil }
        case .minutes:
            return decimal(trimmed).flatMap {
                DomainLimits.setMinutes.contains($0)
                    ? set.with(minutes: $0, distanceM: set.distanceM).with(sec: Int(($0 * 60).rounded())) : nil
            }
        case .distance:
            if trimmed.isEmpty { return set.with(minutes: set.minutes, distanceM: nil) }
            return decimal(trimmed).map { $0 * metersPerDistanceUnit(unit) }
                .flatMap { DomainLimits.setDistanceM.contains($0) ? set.with(minutes: set.minutes, distanceM: $0) : nil }
        }
    }

    private static func decimal(_ text: String) -> Double? {
        LocalizedNumber.parse(text).flatMap { $0 >= 0 ? $0 : nil }
    }

    /// "mi" for lb-unit profiles, "km" otherwise. Shared with `WorkoutText`'s cardio summary.
    static func distanceUnit(_ unit: WeightUnit) -> String { unit == .lb ? "mi" : "km" }

    /// Meters per displayed distance unit. Shared with `WorkoutText`'s cardio summary.
    static func metersPerDistanceUnit(_ unit: WeightUnit) -> Double { unit == .lb ? metersPerMile : 1_000 }
}
