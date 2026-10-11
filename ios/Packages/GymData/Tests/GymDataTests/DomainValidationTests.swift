import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Repositories refuse values the server's CHECK constraints would reject (see `DomainLimits`).
@MainActor
@Suite struct DomainValidationTests {
    let container: ModelContainer
    let clock: () -> Date = { Date(timeIntervalSince1970: 1_790_000_000) }

    init() throws { container = try GymStore.container(inMemory: true) }

    @Test func routineNameLongerThan40IsRejected() throws {
        let repo = RoutineRepository(context: container.mainContext, now: clock)
        #expect(throws: GymDataError.invalidInput("Routine names can be up to 40 characters.")) {
            try repo.upsert(Routine(name: String(repeating: "a", count: 41), exercises: []))
        }
        #expect(try repo.all().isEmpty)
    }

    @Test func routineWithMoreThan20ExercisesIsRejected() throws {
        let repo = RoutineRepository(context: container.mainContext, now: clock)
        let items = (0..<21).map { RoutineExercise(exerciseId: "e\($0)", sets: 3, reps: 8) }
        #expect(throws: GymDataError.invalidInput("A routine can have up to 20 exercises.")) {
            try repo.upsert(Routine(name: "Big", exercises: items))
        }
        try repo.upsert(Routine(name: "Just right", exercises: Array(items.prefix(20))))
        #expect(try repo.all().count == 1)
    }

    @Test func customExerciseNameLongerThan80IsRejected() throws {
        let repo = CustomExerciseRepository(context: container.mainContext, now: clock)
        #expect(throws: GymDataError.invalidInput("Names can be up to 80 characters.")) {
            try repo.create(name: String(repeating: "x", count: 81), bodyPart: "legs", equipment: "sled",
                            target: "quads", mode: .reps, bilateral: false)
        }
        #expect(try repo.all().isEmpty)
    }

    @Test func bodyweightOutOfRangeIsRejected() throws {
        let repo = BodyRepository(context: container.mainContext, now: clock)
        #expect(throws: GymDataError.invalidInput("Enter a weight between 30 and 300 kg")) {
            try repo.add(BodyweightEntry(date: clock(), weightKg: 400))
        }
        #expect(throws: GymDataError.invalidInput("Enter a body fat between 3 and 60%")) {
            try repo.add(BodyweightEntry(date: clock(), weightKg: 80, bodyFatPct: 70))
        }
        #expect(try repo.entries(since: nil).isEmpty)
    }

    @Test func profileOutOfRangeIsRejected() throws {
        let repo = ProfileRepository(context: container.mainContext, now: clock)
        #expect(throws: GymDataError.self) { try repo.save(Profile(restSec: 1_000)) }
        #expect(throws: GymDataError.self) { try repo.save(Profile(goalWeightKg: 20)) }
        #expect(throws: GymDataError.self) { try repo.save(Profile(trainingDays: 0)) }
        try repo.save(Profile(unit: .kg))
        #expect(try repo.load().unit == .kg)
    }
}
