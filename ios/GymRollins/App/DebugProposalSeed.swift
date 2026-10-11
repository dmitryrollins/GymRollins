#if DEBUG
import Foundation
import GymCore
import GymData
import SwiftData

/// DEBUG-only (`-seedProposal`): a pending proposal shaped like the shared fixture's "valid knee-break proposal",
/// mapped onto `OwnerSeed`'s routines and exercise ids, with one visible effect per change (four cards). Inserted
/// once (fixed id), so a relaunch on the same disk store keeps its resolution.
enum DebugProposalSeed {
    static let id = UUID(uuidString: "C1A0DE00-0000-4000-8000-000000000001")!
    static let heavierBenchKg = UnitConverter.toKg(145, from: .lb)

    @MainActor
    static func apply(context: ModelContext, now: Date) throws {
        let proposals = ProposalRepository(context: context, now: { now })
        guard try proposals.proposal(id) == nil else { return }
        let routines = try RoutineRepository(context: context, now: { now }).all()
        func ref(_ name: String) -> String? {
            routines.first { $0.name == name }?.id.uuidString.lowercased()
        }
        guard let push = ref("Push + Arms"), let pull = ref("Pull + Shoulders + Triceps"), let legs = ref("Legs"),
              let upper = ref("Upper weak points") else { return }
        let seed = Proposal(id: id, createdAt: now.addingTimeInterval(-3_600),
                            summary: "Knee break: replace Legs with upper work for ~4 weeks", changes: [
            PlanChange(id: "c1", type: .week, routineId: upper, weekday: 7, reason: "An extra upper day while legs rest"),
            PlanChange(id: "c2", type: .weight, routineId: push, exerciseId: "0025", weightKg: heavierBenchKg,
                       reason: "Hit the top of the range twice"),
            PlanChange(id: "c3", type: .swapExercise, routineId: pull, exerciseId: "0603", toExerciseId: "0405",
                       reason: "Stalled 3 sessions"),
            PlanChange(id: "c4", type: .removeExercise, routineId: legs, exerciseId: "0585", reason: "Knee"),
        ])
        try proposals.upsertRemote(try proposals.pending() + [seed])
    }

    static let todayId = UUID(uuidString: "C1A0DE00-0000-4000-8000-000000000002")!

    /// `-seedTodayProposal`: Claude's one-off home session — a new "Home · KB Upper" routine (two kettlebell
    /// exercises) picked for today with a `today` change; the week schedule is untouched.
    @MainActor
    static func applyToday(context: ModelContext, now: Date) throws {
        let proposals = ProposalRepository(context: context, now: { now })
        guard try proposals.proposal(todayId) == nil else { return }
        let seed = Proposal(id: todayId, createdAt: now.addingTimeInterval(-600),
                            summary: "Home today: kettlebell upper session instead of the gym", changes: [
            PlanChange(id: "c1", type: .addRoutine, routineId: "home-kb", name: "Home \u{00B7} KB Upper"),
            PlanChange(id: "c2", type: .addExercise, routineId: "home-kb", exerciseId: "0520", sets: 3, reps: 10),
            PlanChange(id: "c3", type: .addExercise, routineId: "home-kb", exerciseId: "0522", sets: 3, reps: 12),
            PlanChange(id: "c4", type: .today, routineId: "home-kb", date: TodayPlan.dayKey(now),
                       reason: "Training at home today"),
        ])
        try proposals.upsertRemote(try proposals.pending() + [seed])
    }
}
#endif
