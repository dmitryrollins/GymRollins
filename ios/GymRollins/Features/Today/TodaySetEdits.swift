import Foundation
import GymCore

/// Pure edits of one exercise's planned sets for today (before the workout starts; see `TodayPlanEditor`). Every edit
/// keeps at least one working set and at most `maxWorkingSets` (the routine's limit), so a saved routine item stays
/// valid.
enum TodaySetEdits {
    /// Same bound as a routine item's `sets` (plan validation: 1–10).
    static let maxWorkingSets = 10
    static let maxWarmups = 5

    static func workingCount(_ sets: [WorkoutSet]) -> Int { sets.filter { !$0.warmup }.count }

    /// One set replaced by `set` (e.g. `SetFieldFormat.applying`'s result for any field).
    static func replacing(_ sets: [WorkoutSet], index: Int, with set: WorkoutSet) -> [WorkoutSet] {
        replacing(sets, index: index) { _ in set }
    }

    /// Appends a copy of the last working set (or of the last set, as a working set, when there are only warm-ups).
    static func adding(to sets: [WorkoutSet]) -> [WorkoutSet] {
        guard workingCount(sets) < maxWorkingSets, let template = sets.last(where: { !$0.warmup }) ?? sets.last
        else { return sets }
        return sets + [fresh(template, warmup: false)]
    }

    /// Removes one set unless it's the last working set.
    static func removing(from sets: [WorkoutSet], index: Int) -> [WorkoutSet] {
        guard sets.indices.contains(index), sets[index].warmup || workingCount(sets) > 1 else { return sets }
        return sets.enumerated().filter { $0.offset != index }.map(\.element)
    }

    /// Flips one set between warm-up and working, keeping at least one working set and the limits.
    static func togglingWarmup(_ sets: [WorkoutSet], index: Int) -> [WorkoutSet] {
        guard sets.indices.contains(index) else { return sets }
        let set = sets[index]
        if set.warmup {
            guard workingCount(sets) < maxWorkingSets else { return sets }
        } else {
            guard workingCount(sets) > 1, sets.count - workingCount(sets) < maxWarmups else { return sets }
        }
        return replacing(sets, index: index) { fresh($0, warmup: !$0.warmup, keepId: true) }
    }

    /// The routine item that plays back these sets: working set count, reps (or seconds) and the heaviest working
    /// weight, stamped `now` so it overrides progression next time. Reps inside the item's range keep the range (today's
    /// target is usually its bottom, set by double progression); reps outside it move the top, and a range bottom above
    /// the new top is dropped.
    static func routineItem(_ item: RoutineExercise, from sets: [WorkoutSet], at now: Date) -> RoutineExercise {
        let working = sets.filter { !$0.warmup }
        guard !working.isEmpty else { return item }
        let top = working.map(\.reps).max() ?? item.reps
        let bottom = working.map(\.reps).min() ?? top
        let withinRange = bottom >= (item.repsMin ?? item.reps) && top <= item.reps
        let reps = withinRange ? item.reps : top
        let sec = item.sec == nil ? nil : working.compactMap(\.sec).max() ?? item.sec
        let weight = working.map(\.weightKg).max() ?? 0
        // The owner saved exactly this load — even when it equals the routine's old value or is zero (bodyweight) while
        // history has heavier sets: store and stamp it so the planned weight wins over progression next time.
        return RoutineExercise(id: item.id, exerciseId: item.exerciseId, sets: min(working.count, maxWorkingSets),
                               reps: reps, repsMin: item.repsMin.flatMap { $0 <= reps ? $0 : nil }, sec: sec,
                               weightKg: weight, mode: item.mode,
                               policy: item.policy, incKg: item.incKg, supersetGroup: item.supersetGroup,
                               weightSetAt: now)
    }

    private static func replacing(_ sets: [WorkoutSet], index: Int,
                                  _ transform: (WorkoutSet) -> WorkoutSet) -> [WorkoutSet] {
        sets.enumerated().map { $0.offset == index ? transform($0.element) : $0.element }
    }

    private static func fresh(_ set: WorkoutSet, warmup: Bool, keepId: Bool = false) -> WorkoutSet {
        WorkoutSet(id: keepId ? set.id : UUID(), weightKg: set.weightKg, reps: set.reps, sec: set.sec,
                   minutes: set.minutes, distanceM: set.distanceM, warmup: warmup, multiplier: set.multiplier)
    }
}
