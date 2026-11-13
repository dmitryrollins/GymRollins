import Foundation
import GymCore

extension WorkoutSession {
    /// Applies a Live Activity button (or an Apple Watch action) through the same operations the logging screen uses.
    /// Returns false (and changes nothing) when the action no longer applies: another workout, a finished or abandoned
    /// session, a set that is no longer the next one, a non-reps exercise, no running rest, or an exercise that is no
    /// longer the one shown.
    @discardableResult
    func perform(_ action: WorkoutActivityAction, exercise: (String) -> Exercise?) -> Bool {
        guard action.workoutId == workout.id, workout.endedAt == nil, !isAbandoned else { return false }
        switch action {
        case .logPlannedSet(_, let entryId, let setId):
            return logSet(entryId: entryId, setId: setId, exercise: exercise) { ($0.weight, $0.reps) }
        case .logSet(_, let entryId, let setId, let weightKg, let weightLb, let reps):
            // Without a pound number the set keeps its own while the kg is unchanged (`PoundWeight.replacing`).
            return logSet(entryId: entryId, setId: setId, exercise: exercise) { set in
                (weightLb.map { PoundWeight(kg: weightKg, lb: $0) } ?? PoundWeight.replacing(set.weight, kg: weightKg),
                 reps)
            }
        case .showExercise(_, let fromEntryId, let step):
            // Only from the exercise shown right now: a queued tap made on an older screen doesn't jump around.
            guard WorkoutActivityContent.targetEntry(in: workout, currentEntryId: currentEntryId)?.id == fromEntryId,
                  let target = WorkoutActivityContent.neighbor(of: fromEntryId, step: step, in: workout) else {
                return false
            }
            select(target.id)
            return true
        case .extendRest(_, let entryId, let seconds):
            guard activeRest(at: currentDate) != nil else { return false }
            keepShowing(entryId)
            adjustRest(by: seconds)
            return true
        case .skipRest(_, let entryId):
            guard activeRest(at: currentDate) != nil else { return false }
            keepShowing(entryId)
            skipRest()
            return true
        }
    }

    /// Logs `setId` (still the entry's next set, reps-based) with `values(set)`. Lock screen and watch both offer Log set
    /// while resting (the app's rest bar doesn't): logging ends that rest, and `logNextSet` starts a new one unless this
    /// was the exercise's last set.
    private func logSet(entryId: UUID, setId: UUID, exercise: (String) -> Exercise?,
                        values: (WorkoutSet) -> (weight: PoundWeight, reps: Int)) -> Bool {
        guard let entry = entry(entryId), entry.sets.first(where: { !$0.done })?.id == setId,
              WorkoutActivityContent.canLogPlannedSet(entry, exercise: exercise(entry.exerciseId)),
              let set = entry.sets.first(where: { $0.id == setId }) else { return false }
        select(entryId) // the activity keeps following the exercise it showed, even after a cold start
        if rest != nil { skipRest() }
        let (weight, reps) = values(set)
        logNextSet(entryId: entryId, weight: weight, reps: reps, sec: set.sec)
        return true
    }

    /// Re-selects the entry the activity showed when it still has an undone set (after a cold start the current entry
    /// resets to the first with undone sets, which would switch the activity to another exercise).
    private func keepShowing(_ entryId: UUID?) {
        guard let entryId, entry(entryId)?.sets.contains(where: { !$0.done }) == true else { return }
        select(entryId)
    }
}
