#if DEBUG
import Foundation
import GymCore
import GymData
import SwiftData

/// DEBUG-only (`-seedKgPlanWeight`): Push's Barbell Bench Press planned at 20.3 kg with no pound number, the way an agent
/// sent 45 lb before plan 38 (it shows as 44.8 lb). The launch's plan weight cleanup (`PlanWeightsLbCleanup`) then
/// gives it its pound number, which the UI test checks.
enum DebugPlanWeightSeed {
    static let agentKg = 20.3

    @MainActor
    static func apply(context: ModelContext, now: Date) throws {
        let routines = RoutineRepository(context: context, now: { now })
        guard let push = try routines.all().first(where: { $0.name == "Push + Arms" }) else { return }
        let items = push.exercises.map { item in
            item.exerciseId == "0025"
                ? RoutineExercise(id: item.id, exerciseId: item.exerciseId, sets: item.sets, reps: item.reps,
                                  repsMin: item.repsMin, sec: item.sec, weightKg: agentKg, mode: item.mode,
                                  policy: item.policy, incKg: item.incKg, supersetGroup: item.supersetGroup)
                : item
        }
        try routines.upsert(Routine(id: push.id, name: push.name, emoji: push.emoji, policy: push.policy,
                                    paused: push.paused, exercises: items))
    }
}
#endif
