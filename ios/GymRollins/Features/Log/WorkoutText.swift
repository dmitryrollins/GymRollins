import Foundation
import GymCore

/// Pure text formatting for workout log summaries.
enum WorkoutText {
    /// Summarizes an entry's working sets (warm-ups excluded), formatted for `mode`:
    /// - `.reps` equal weight and reps: "3 × 10 @ 130 lb".
    /// - `.reps` equal weight, varying reps: "10, 10, 12 @ 44 lb".
    /// - `.reps` varying weight: "12, 12 @ 25–27.5 lb" (reps listed, weight shown as a range).
    /// - `.reps` bodyweight (all weights ~0): reps only, e.g. "10, 10, 8".
    /// - `.time` equal duration: "3 × 0:30"; varying: "0:30, 0:45".
    /// - `.cardio`: "20 min · 3.2 km" (or "mi" by unit), or "20 min" without distance.
    static func setsSummary(_ entry: WorkoutEntry, unit: WeightUnit, mode: ExerciseMode = .reps) -> String {
        let sets = WorkoutMetrics.workingSets(entry)
        guard !sets.isEmpty else { return "" }
        switch mode {
        case .reps: return repsSummary(sets, unit: unit)
        case .time: return timeSummary(sets)
        case .cardio: return cardioSummary(sets, unit: unit)
        }
    }

    /// Weights show their pound numbers in lb (plan 38); whether they're equal is still decided in kg.
    private static func repsSummary(_ sets: [WorkoutSet], unit: WeightUnit) -> String {
        let weights = sets.map(\.weight)
        let reps = sets.map(\.reps)
        let repsText = reps.map(String.init).joined(separator: ", ")

        if weights.allSatisfy({ abs($0.kg) < 0.01 }) { return repsText }

        let first = weights[0]
        let weightsEqual = weights.allSatisfy { abs($0.kg - first.kg) < 0.01 }
        if weightsEqual {
            let repsEqual = reps.allSatisfy { $0 == reps[0] }
            if repsEqual {
                return "\(sets.count) \u{00D7} \(reps[0]) @ \(weightText(first, unit: unit))"
            }
            return "\(repsText) @ \(weightText(first, unit: unit))"
        }

        let lightest = weights.min { $0.kg < $1.kg } ?? first
        let heaviest = weights.max { $0.kg < $1.kg } ?? first
        let range = "\(number(lightest, unit: unit))\u{2013}\(number(heaviest, unit: unit)) \(unit.rawValue)"
        return "\(repsText) @ \(range)"
    }

    private static func timeSummary(_ sets: [WorkoutSet]) -> String {
        let secs = sets.map { $0.sec ?? 0 }
        if secs.allSatisfy({ $0 == secs[0] }) {
            return "\(sets.count) \u{00D7} \(DurationFormatter.clock(TimeInterval(secs[0])))"
        }
        return secs.map { DurationFormatter.clock(TimeInterval($0)) }.joined(separator: ", ")
    }

    private static func cardioSummary(_ sets: [WorkoutSet], unit: WeightUnit) -> String {
        let totalMinutes = sets.reduce(0.0) { $0 + ($1.minutes ?? $1.sec.map { Double($0) / 60 } ?? 0) }
        let totalDistanceM = sets.reduce(0.0) { $0 + ($1.distanceM ?? 0) }
        let minutesText = WeightFormatter.number(totalMinutes)
        guard totalDistanceM > 0 else { return "\(minutesText) min" }
        let distanceText = WeightFormatter.number(totalDistanceM / SetFieldFormat.metersPerDistanceUnit(unit))
        return "\(minutesText) min \u{00B7} \(distanceText) \(SetFieldFormat.distanceUnit(unit))"
    }

    private static func weightText(_ weight: PoundWeight, unit: WeightUnit) -> String {
        "\(number(weight, unit: unit)) \(unit.rawValue)"
    }

    private static func number(_ weight: PoundWeight, unit: WeightUnit) -> String {
        WeightFormatter.number(kg: weight.kg, lb: weight.lb, unit: unit)
    }
}
