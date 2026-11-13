import Foundation
import GymCore
import GymData

extension AppEnvironment {
    /// Whether Today asks about the injury note: its end date has come by `date` (now, when none is given).
    func limitsCheckInDue(at date: Date? = nil) -> Bool {
        LimitsCheckIn.isDue(note: profile.limits, until: profile.limitsUntil, now: date ?? now(), calendar: .current)
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

    /// 60% of what Today would suggest for `item` now, from this person's history, with no gym fitting. In lb it has
    /// its pound number (the rounder's grid value), so it shows as 80 lb and not 79.9.
    private func returnWeight(for item: RoutineExercise, in routine: Routine) -> PoundWeight? {
        let exercise = library.exercise(item.exerciseId)
        let history = (try? workouts.history(exerciseId: item.exerciseId, limit: 5)) ?? []
        let suggested = SessionPlanner.suggestion(for: item, policy: item.policy ?? routine.policy, profile: profile,
                                                  exercise: exercise, history: history).weightKg
        let rounder = LoadRounding.rounder(for: exercise, profile: profile)
        let smallest = (exercise?.isBarbellLoaded ?? false)
            ? emptyBar : PoundWeight.entered(rounder.step, unit: rounder.unit)
        guard let light = ReturnWeights.weight(from: suggested, rounder: rounder, minimum: smallest) else { return nil }
        // The engine plans a weight only when it differs from the last logged one by more than this. A floor clamp that
        // lands on the last weight would be ignored and progression would take over, so it isn't counted.
        let tolerance = 0.01
        guard suggested - light.kg > tolerance else { return nil }
        if let last = history.first?.weightKg, abs(light.kg - last) <= tolerance { return nil }
        return light
    }

    /// The profile's bar, with its pound number when the bar and plates are set up in pounds.
    private var emptyBar: PoundWeight {
        let inventory = profile.plateInventory
        return PoundWeight(kg: profile.barKg, lb: inventory.unit == .lb ? inventory.bar : nil)
    }
}
