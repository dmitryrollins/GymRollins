import Foundation
import GymCore
import GymData

struct TodayModel: Equatable {
    struct Row: Equatable, Identifiable {
        let id: UUID
        let exerciseId: String
        let name: String
        let bodyPart: String
        let subtitle: String
        let badge: String?
        let suggestedKg: Double?
        /// The sets were edited on Today (they no longer follow the suggestion).
        var setsEdited = false
    }

    let routineId: UUID?
    let title: String
    let summary: String
    let rows: [Row]

    static func make(routine: Routine?, profile: Profile, library: ExerciseLibrary,
                     history: (String) -> [SessionResult]) -> TodayModel {
        guard let routine else {
            return TodayModel(routineId: nil, title: "Rest day", summary: "Recover and eat well", rows: [])
        }
        let rows = routine.exercises.map { item -> Row in
            let ex = library.exercise(item.exerciseId)
            let past = history(item.exerciseId)
            let suggestion = SessionPlanner.suggestion(for: item, policy: item.policy ?? routine.policy,
                                                       profile: profile, exercise: ex, history: past)
            let reps = item.repsMin.map { $0 < item.reps ? "\($0)\u{2013}\(item.reps)" : "\(item.reps)" } ?? "\(item.reps)"
            let load = suggestion.weightKg > 0
                ? " \u{00B7} " + WeightFormatter.format(kg: suggestion.weightKg, unit: profile.unit)
                : ""
            let delta = past.first.map { suggestion.weightKg - $0.weightKg } ?? 0
            let badge = delta > 0.01
                ? "+\(WeightFormatter.format(kg: delta, unit: profile.unit, includeSecondary: false))"
                : nil
            return Row(id: item.id, exerciseId: item.exerciseId, name: DisplayName.of(ex?.name ?? item.exerciseId),
                       bodyPart: ex?.bodyPart ?? "", subtitle: "\(item.sets) \u{00D7} \(reps)\(load)", badge: badge,
                       suggestedKg: suggestion.weightKg > 0 ? suggestion.weightKg : nil)
        }
        let count = rows.count == 1 ? "1 exercise" : "\(rows.count) exercises"
        return TodayModel(routineId: routine.id, title: routine.name, summary: count, rows: rows)
    }

    /// Today's model for a `TodayPlan`: the rows of its exercises, with a summary saying what kind of day it is.
    static func make(plan: TodayPlan, profile: Profile, library: ExerciseLibrary,
                     history: (String) -> [SessionResult]) -> TodayModel {
        let routine = plan.base?.with(exercises: plan.exercises) ?? Routine(name: plan.title, exercises: plan.exercises)
        let rows = make(routine: routine, profile: profile, library: library, history: history).rows.map { row in
            guard let sets = plan.sets(for: row.id) else { return row }
            return Row(id: row.id, exerciseId: row.exerciseId, name: row.name, bodyPart: row.bodyPart,
                       subtitle: subtitle(sets: sets, unit: profile.unit), badge: nil,
                       suggestedKg: row.suggestedKg, setsEdited: true)
        }
        let count = rows.count == 1 ? "1 exercise" : "\(rows.count) exercises"
        let summary: String
        switch plan.kind {
        case .empty where rows.isEmpty: summary = "Add exercises, or start and add them as you go"
        case .restDaySuggestion where !plan.edited: summary = "Rest day \u{00B7} optional \u{00B7} \(count)"
        default: summary = plan.edited ? "\(count) \u{00B7} edited for today" : count
        }
        return TodayModel(routineId: plan.base?.id, title: plan.title, summary: summary, rows: rows)
    }

    /// "3 × 10 · 140 lb" for edited sets: working sets, their top reps (or seconds) and top weight.
    static func subtitle(sets: [WorkoutSet], unit: WeightUnit) -> String {
        let working = sets.filter { !$0.warmup }
        let top = working.map(\.reps).max() ?? 0
        let low = working.map(\.reps).min() ?? 0
        let secs = working.compactMap(\.sec).max()
        let amount = secs.map { "\($0) s" } ?? (low < top ? "\(low)\u{2013}\(top)" : "\(top)")
        let weight = working.map(\.weightKg).max() ?? 0
        let load = weight > 0 ? " \u{00B7} " + WeightFormatter.format(kg: weight, unit: unit) : ""
        return "\(working.count) \u{00D7} \(amount)\(load)"
    }
}
