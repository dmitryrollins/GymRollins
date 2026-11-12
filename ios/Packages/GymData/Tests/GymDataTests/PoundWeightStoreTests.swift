import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Sets and plan items keep their pound number in the store (plan 38), and rows without one read nil.
@MainActor
@Suite struct PoundWeightStoreTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }

    @Test func aPlanItemKeepsItsPoundNumber() throws {
        let container = try GymStore.container(inMemory: true)
        let context = container.mainContext
        let routine = RoutineRecord(id: UUID(), name: "Push", emoji: nil, policyRaw: "double", position: 0,
                                    paused: false, now: .now)
        context.insert(routine)
        routine.exercises = [
            RoutineExerciseRecord(RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, weightKg: lb(45), weightLb: 45),
                                  position: 0),
            RoutineExerciseRecord(RoutineExercise(exerciseId: "0314", sets: 3, reps: 10, weightKg: 20), position: 1),
        ]
        try context.save()
        let stored = try #require(try context.fetch(FetchDescriptor<RoutineRecord>()).first)
        #expect(stored.exercises.sorted { $0.position < $1.position }.map(\.weightLb) == [45, nil])
        let value = stored.value
        #expect(value.exercises.map(\.weightLb) == [45, nil])
        #expect(value.exercises[0].weight == PoundWeight.entered(45, unit: .lb))
    }

    @Test func aSetKeepsItsPoundNumberThroughTheRowsAndTheCache() throws {
        let container = try GymStore.container(inMemory: true)
        let context = container.mainContext
        let entry = WorkoutEntry(exerciseId: "0025", sets: [
            WorkoutSet(weightKg: lb(47.5), weightLb: 47.5, reps: 8, done: true),
            WorkoutSet(weightKg: 20, reps: 8, done: true),
        ])
        let record = WorkoutRecord(id: UUID(), startedAt: .now, name: "Push", sourceRaw: "app", isActive: false,
                                   now: .now)
        context.insert(record)
        try record.setEntries([entry], in: context)
        try context.save()
        #expect(record.entries.first?.sets.sorted { $0.position < $1.position }.map(\.weightLb) == [47.5, nil])
        #expect(record.value.entries[0].sets.map(\.weightLb) == [47.5, nil], "from the cache")
        record.entriesData = nil
        #expect(record.value.entries[0].sets.map(\.weightLb) == [47.5, nil], "from the rows")
    }

    @Test func aRowWithADisagreeingPoundNumberReadsNil() throws {
        let set = SetRecord(id: UUID(), position: 0, weightKg: 20.3, weightLb: 45, reps: 5, sec: nil, minutes: nil,
                            distanceM: nil, done: true, warmup: false, rir: nil, rpe: nil, multiplier: 1,
                            completedAt: nil)
        #expect(set.value.weightLb == nil && set.value.weightKg == 20.3)
        let item = RoutineExerciseRecord(id: UUID(), exerciseId: "b", position: 0, sets: 3, reps: 5, repsMin: nil,
                                         sec: nil, weightKg: 20.3, weightLb: 45, weightSetAt: nil, modeRaw: "reps",
                                         policyRaw: nil, incKg: nil, supersetGroup: nil)
        #expect(item.value.weightLb == nil)
    }

    @Test func rowsWrittenWithoutAPoundNumberReadNil() {
        let set = SetRecord(id: UUID(), position: 0, weightKg: 20, reps: 5, sec: nil, minutes: nil, distanceM: nil,
                            done: true, warmup: false, rir: nil, rpe: nil, multiplier: 1, completedAt: nil)
        #expect(set.weightLb == nil && set.value.weightLb == nil)
        let item = RoutineExerciseRecord(id: UUID(), exerciseId: "b", position: 0, sets: 3, reps: 5, repsMin: nil,
                                         sec: nil, weightKg: 20, weightSetAt: nil, modeRaw: "reps", policyRaw: nil,
                                         incKg: nil, supersetGroup: nil)
        #expect(item.weightLb == nil && item.value.weightLb == nil)
    }

    @Test func aSessionResultTakesTheTopSetsPoundNumber() throws {
        let entry = WorkoutEntry(exerciseId: "0025", sets: [
            WorkoutSet(weightKg: lb(45), weightLb: 45, reps: 10, done: true, warmup: true),
            WorkoutSet(weightKg: lb(95), reps: 8, done: true),
            WorkoutSet(weightKg: lb(95), weightLb: 95, reps: 8, done: true),
        ])
        let result = try #require(SessionHistory.result(for: entry, date: .now))
        #expect(result.weight == PoundWeight.entered(95, unit: .lb))
        let none = WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 20.3, reps: 8, done: true)])
        #expect(try #require(SessionHistory.result(for: none, date: .now)).weightLb == nil)
    }
}
