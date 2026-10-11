import Foundation
import GymCore

/// Pure rules for what the workout Live Activity shows: which entry and set are "next", how the set reads in the
/// user's unit, whether Log set is offered (reps-based exercises only), and the running rest.
enum WorkoutActivityContent {
    /// The content state for `workout`, or nil once it is finished (the activity ends then).
    static func state(workout: Workout, currentEntryId: UUID?, rest: RestTimer?, now: Date, unit: WeightUnit,
                      exercise: (String) -> Exercise?) -> WorkoutActivityAttributes.ContentState? {
        guard workout.endedAt == nil else { return nil }
        let running = rest.flatMap { $0.isFinished(at: now) ? nil : $0 }
        guard let entry = targetEntry(in: workout, currentEntryId: currentEntryId),
              let index = entry.sets.firstIndex(where: { !$0.done }) else {
            return WorkoutActivityAttributes.ContentState(
                exerciseName: workout.name, setLabel: workout.entries.isEmpty ? "Add an exercise" : "All sets done",
                setDetail: "", restStartedAt: running?.startedAt, restEndsAt: running?.endsAt, canLogSet: false,
                entryId: nil, setId: nil, isComplete: true)
        }
        let info = exercise(entry.exerciseId)
        let set = entry.sets[index]
        let mode = SetFieldFormat.mode(exercise: info, sets: entry.sets)
        return WorkoutActivityAttributes.ContentState(
            exerciseName: DisplayName.of(info?.name ?? entry.exerciseId),
            setLabel: setLabel(entry.sets, index: index),
            setDetail: setDetail(set, mode: mode, unit: unit),
            restStartedAt: running?.startedAt, restEndsAt: running?.endsAt,
            canLogSet: mode == .reps, entryId: entry.id, setId: set.id, isComplete: false)
    }

    /// The session's current entry while it still has an undone set, otherwise the first entry that has one.
    static func targetEntry(in workout: Workout, currentEntryId: UUID?) -> WorkoutEntry? {
        if let current = workout.entries.first(where: { $0.id == currentEntryId }), current.sets.contains(where: { !$0.done }) {
            return current
        }
        return workout.entriesWithUndoneSets.first
    }

    /// The exercise before/after `entryId` among those with sets left (the order the workout shows them), nil at
    /// either end or when `entryId` has no sets left.
    static func neighbor(of entryId: UUID, step: ExerciseStep, in workout: Workout) -> WorkoutEntry? {
        let open = workout.entriesWithUndoneSets
        guard let index = open.firstIndex(where: { $0.id == entryId }) else { return nil }
        let target = step == .next ? index + 1 : index - 1
        return open.indices.contains(target) ? open[target] : nil
    }

    /// Log set from the lock screen: only for reps-based sets (the same mode rule the logging screen uses), and only
    /// while the entry has a next set.
    static func canLogPlannedSet(_ entry: WorkoutEntry, exercise: Exercise?) -> Bool {
        entry.sets.contains { !$0.done } && SetFieldFormat.mode(exercise: exercise, sets: entry.sets) == .reps
    }

    /// "Set 3/5" among working sets, "Warm-up 1/2" among warm-ups.
    static func setLabel(_ sets: [WorkoutSet], index: Int) -> String {
        let ordinal = SetOrdinal.ordinals(for: sets)[index]
        switch ordinal {
        case .warmup(let n): return "Warm-up \(n)/\(sets.filter(\.warmup).count)"
        case .working(let n): return "Set \(n)/\(sets.filter { !$0.warmup }.count)"
        }
    }

    /// The planned values in the user's unit: "60 kg × 8" (or "8 reps" without load), "45 s", "20 min · 3.1 mi".
    static func setDetail(_ set: WorkoutSet, mode: ExerciseMode, unit: WeightUnit) -> String {
        switch mode {
        case .reps:
            guard set.weightKg > 0 else { return "\(set.reps) reps" }
            return "\(WeightFormatter.format(kg: set.weightKg, unit: unit, includeSecondary: false)) \u{00D7} \(set.reps)"
        case .time:
            let seconds = set.sec.map { "\($0) s" } ?? ""
            guard set.weightKg > 0 else { return seconds }
            return [seconds, WeightFormatter.format(kg: set.weightKg, unit: unit, includeSecondary: false)]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        case .cardio:
            let minutes = SetFieldFormat.display(.minutes(set.id), set: set, unit: unit)
            let distance = SetFieldFormat.display(.distance(set.id), set: set, unit: unit)
            return [minutes.isEmpty ? "" : "\(minutes) min",
                    distance.isEmpty ? "" : "\(distance) \(SetFieldFormat.distanceUnit(unit))"]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }
}
