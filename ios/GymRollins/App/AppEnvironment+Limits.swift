import Foundation
import GymCore
import GymData

extension AppEnvironment {
    /// Whether Today asks about the injury note: its end date has come.
    var limitsCheckInDue: Bool {
        LimitsCheckIn.isDue(note: profile.limits, until: profile.limitsUntil, now: now(), calendar: .current)
    }

    /// Saves the injury note and its end date. An empty note keeps no date (`Profile.withLimits`).
    func saveLimits(_ note: String, until: Date?) throws {
        try profiles.save(profile.withLimits(note, until: until))
        reloadProfile()
        planChanged()
    }

    /// The check-in's Yes: the note and its date go.
    func clearLimits() throws { try saveLimits("", until: nil) }

    /// The check-in's Not yet: ask again on `date`.
    func postponeLimits(to date: Date) throws { try saveLimits(profile.limits, until: date) }

    func pausedRoutines() throws -> [Routine] { try routines.all().filter(\.paused) }

    /// Resume at 60%: the routine unpaused with its weighted exercises lowered, in one save, so a failure leaves it as it
    /// was. Nil when it's gone or already back.
    func resumeAtReturnWeights(_ routineId: UUID) throws -> (name: String, lowered: Int)? {
        guard let routine = try routines.routine(routineId), routine.paused else { return nil }
        let result = ReturnWeights.resume(routine, now: now()) { returnWeight(for: $0, in: routine) }
        try routines.upsert(result.routine)
        planChanged()
        return (routine.name, result.lowered)
    }

    /// 60% of what Today would suggest for `item` now, from this person's history, with no gym fitting.
    private func returnWeight(for item: RoutineExercise, in routine: Routine) -> Double? {
        let exercise = library.exercise(item.exerciseId)
        let history = (try? workouts.history(exerciseId: item.exerciseId, limit: 5)) ?? []
        let suggested = SessionPlanner.suggestion(for: item, policy: item.policy ?? routine.policy, profile: profile,
                                                  exercise: exercise, history: history).weightKg
        let rounder = LoadRounding.rounder(for: exercise, profile: profile)
        let smallest = (exercise?.isBarbellLoaded ?? false)
            ? profile.barKg : UnitConverter.toKg(rounder.step, from: rounder.unit)
        return ReturnWeights.weight(from: suggested, rounder: rounder, minimumKg: smallest)
    }
}
