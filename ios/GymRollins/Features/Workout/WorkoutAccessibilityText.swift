import Foundation
import GymCore

/// A set's place in its entry: warm-ups and working sets are numbered separately ("W" badges vs 1, 2, 3).
enum SetOrdinal: Equatable {
    case warmup(Int)
    case working(Int)

    /// 1-based working-set index, or nil for a warm-up.
    var workingPosition: Int? {
        if case .working(let n) = self { return n }
        return nil
    }

    static func ordinals(for sets: [WorkoutSet]) -> [SetOrdinal] {
        var warmups = 0
        var working = 0
        return sets.map { set in
            if set.warmup {
                warmups += 1
                return .warmup(warmups)
            }
            working += 1
            return .working(working)
        }
    }
}

/// VoiceOver text for a logging-screen set row, e.g. "Set 1, 8 reps, 140 pounds, done". Pure, for testing.
enum SetAccessibilityText {
    static func rowLabel(set: WorkoutSet, ordinal: SetOrdinal, mode: ExerciseMode, unit: WeightUnit,
                         isActive: Bool, isPlanned: Bool = false) -> String {
        let name: String
        switch ordinal {
        case .warmup(let n): name = "Warm-up set \(n)"
        case .working(let n): name = "Set \(n)"
        }
        // A planned set (Today, before the workout) is neither current nor done: no status.
        let status = isPlanned ? nil : isActive ? "current set" : set.done ? "done" : "not done"
        return ([name] + measures(set: set, mode: mode, unit: unit) + [status].compactMap { $0 }).joined(separator: ", ")
    }

    private static func measures(set: WorkoutSet, mode: ExerciseMode, unit: WeightUnit) -> [String] {
        switch mode {
        case .reps: return [count(set.reps, "rep"), load(set.weightKg, unit: unit)]
        case .time: return [count(set.sec ?? 0, "second"), load(set.weightKg, unit: unit)]
        case .cardio:
            let minutes = set.minutes ?? set.sec.map { Double($0) / 60 }
            let distance = set.distanceM.map { $0 / SetFieldFormat.metersPerDistanceUnit(unit) }
            return [minutes.map { quantity($0, "minute") },
                    distance.map { quantity($0, unit == .lb ? "mile" : "kilometer") }].compactMap { $0 }
        }
    }

    private static func load(_ weightKg: Double, unit: WeightUnit) -> String {
        guard weightKg > 0 else { return "bodyweight" }
        return quantity(UnitConverter.fromKg(weightKg, to: unit), unit == .lb ? "pound" : "kilogram")
    }

    private static func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : "s")" }

    private static func quantity(_ value: Double, _ noun: String) -> String {
        let text = WeightFormatter.number(value)
        return "\(text) \(noun)\(text == "1" ? "" : "s")"
    }
}

/// VoiceOver text for the rest timer: a spoken `accessibilityValue` and sparing announcements (10 s left, rest over).
enum RestAccessibilityText {
    static let restOver = "Rest over"
    static let tenSecondsLeft = "10 seconds left"

    /// "1 minute 45 seconds remaining". Rounds up like the visible clock.
    static func value(remaining: TimeInterval) -> String {
        let total = Int(max(0, remaining).rounded(.up))
        let minutes = total / 60
        let seconds = total % 60
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if seconds > 0 || minutes == 0 { parts.append("\(seconds) second\(seconds == 1 ? "" : "s")") }
        return parts.joined(separator: " ") + " remaining"
    }

    /// The announcement to post when the whole seconds remaining change from `old` to `new`: only when crossing the
    /// 10-second mark downwards, so VoiceOver isn't interrupted every tick.
    static func announcement(from old: Int, to new: Int) -> String? {
        old > 10 && new <= 10 && new > 0 ? tenSecondsLeft : nil
    }
}
