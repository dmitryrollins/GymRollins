import Foundation
import GymCore
import GymData
import GymWatchLink

/// What the Apple Watch shows for the in-progress workout (plan 17). The labels, ids and "next set" rules are the Live
/// Activity's (`WorkoutActivityContent`), so the lock screen and the wrist always agree.
enum WatchStateMapper {
    /// Nil when no workout is in progress (none, finished, or abandoned).
    @MainActor
    static func workout(session: WorkoutSession?, now: Date, profile: Profile, exercise: (String) -> Exercise?,
                        watchRecordsHealth: (UUID) -> Bool) -> WatchWorkout? {
        guard let session, !session.isAbandoned else { return nil }
        let workout = session.workout
        guard let content = WorkoutActivityContent.state(workout: workout, currentEntryId: session.currentEntryId,
                                                          rest: session.rest, now: now, unit: profile.unit,
                                                          exercise: exercise) else { return nil }
        let next = nextSet(content, workout: workout, profile: profile, exercise: exercise)
        let rest = content.restStartedAt.flatMap { start in content.restEndsAt.map { WatchRest(startedAt: start, endsAt: $0) } }
        let shown = content.entryId
        return WatchWorkout(
            id: workout.id, name: workout.name, startedAt: session.clock.startedAt,
            pausedSeconds: session.clock.pausedSeconds, pausedAt: session.clock.pausedAt, next: next,
            status: content.setLabel, rest: rest,
            hasPrevious: shown.flatMap { WorkoutActivityContent.neighbor(of: $0, step: .previous, in: workout) } != nil,
            hasNext: shown.flatMap { WorkoutActivityContent.neighbor(of: $0, step: .next, in: workout) } != nil,
            watchRecordsHealth: watchRecordsHealth(workout.id))
    }

    /// The Digital Crown's grid for `exercise`: the barbell (plates) or dumbbell/machine increment, in the user's unit.
    static func grid(for exercise: Exercise?, profile: Profile) -> WatchLoadGrid {
        let rounder = LoadRounding.rounder(for: exercise, profile: profile)
        let unit = watchUnit(profile.unit)
        guard rounder.unit == profile.unit else {
            let step = UnitConverter.fromKg(UnitConverter.toKg(rounder.step, from: rounder.unit), to: profile.unit)
            return WatchLoadGrid(unit: unit, step: step, offset: 0)
        }
        return WatchLoadGrid(unit: unit, step: rounder.step, offset: rounder.offset)
    }

    /// The kilograms to log for a weight the watch sent. Unchanged from the plan (the watch shows the planned kg in the
    /// user's unit, possibly off the grid) keeps the planned kg exactly, so a round trip never drifts.
    static func loggedKg(weight: Double, unit: WatchWeightUnit, plannedKg: Double) -> Double {
        let appUnit = weightUnit(unit)
        if abs(UnitConverter.fromKg(plannedKg, to: appUnit) - weight) < 0.001 { return plannedKg }
        return UnitConverter.toKg(weight, from: appUnit)
    }

    static func watchUnit(_ unit: WeightUnit) -> WatchWeightUnit { unit == .kg ? .kg : .lb }
    static func weightUnit(_ unit: WatchWeightUnit) -> WeightUnit { unit == .kg ? .kg : .lb }

    private static func nextSet(_ content: WorkoutActivityAttributes.ContentState, workout: Workout, profile: Profile,
                                exercise: (String) -> Exercise?) -> WatchNextSet? {
        guard let entryId = content.entryId, let setId = content.setId,
              let entry = workout.entries.first(where: { $0.id == entryId }),
              let set = entry.sets.first(where: { $0.id == setId }) else { return nil }
        return WatchNextSet(entryId: entryId, setId: setId, exerciseName: content.exerciseName,
                            setLabel: content.setLabel, setDetail: content.setDetail, canLog: content.canLogSet,
                            weight: UnitConverter.fromKg(set.weightKg, to: profile.unit), reps: set.reps,
                            grid: grid(for: exercise(entry.exerciseId), profile: profile))
    }
}
