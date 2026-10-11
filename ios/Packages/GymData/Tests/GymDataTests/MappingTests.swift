import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

@MainActor
@Suite struct MappingTests {
    @Test func routineRoundTripKeepsOrder() throws {
        let container = try GymStore.container(inMemory: true)
        let context = container.mainContext
        let routine = RoutineRecord(id: UUID(), name: "Push + Arms", emoji: nil, policyRaw: "double", position: 0,
                                    paused: false, now: .now)
        context.insert(routine)
        routine.exercises = [
            RoutineExerciseRecord(RoutineExercise(exerciseId: "0314", sets: 3, reps: 10, repsMin: 8), position: 1),
            RoutineExerciseRecord(RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, repsMin: 8, weightKg: 63.5), position: 0),
        ]
        try context.save()
        let value = try #require(try context.fetch(FetchDescriptor<RoutineRecord>()).first).value
        #expect(value.exercises.map(\.exerciseId) == ["0025", "0314"])
        #expect(value.policy == .double)
        #expect(value.exercises[0].weightKg == 63.5)
    }

    @Test func workoutRoundTrip() throws {
        let container = try GymStore.container(inMemory: true)
        let context = container.mainContext
        let entry = WorkoutEntry(exerciseId: "0025", sets: [
            WorkoutSet(weightKg: 20.41, reps: 10, done: true, warmup: true),
            WorkoutSet(weightKg: 58.97, reps: 10, done: true),
        ])
        let record = WorkoutRecord(id: UUID(), startedAt: .now, name: "Push", sourceRaw: "app", isActive: false, now: .now)
        context.insert(record)
        record.entries = [WorkoutEntryRecord(entry, position: 0)]
        try context.save()
        let value = try #require(try context.fetch(FetchDescriptor<WorkoutRecord>()).first).value
        #expect(value.entries[0].sets.map(\.warmup) == [true, false])
        #expect(value.entries[0].sets[1].weightKg == 58.97)
    }
}
