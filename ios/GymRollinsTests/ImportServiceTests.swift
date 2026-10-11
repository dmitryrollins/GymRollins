import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymRollins

@MainActor
@Suite struct ImportServiceTests {
    private let container: ModelContainer
    private let workouts: WorkoutRepository
    private let customs: CustomExerciseRepository
    private let service: ImportService
    /// The user's answers for the fixture's two unresolved names.
    private let choices: [String: ImportPlan.Resolution] = [
        "Dumbbell Biceps Curls": .library("0294"), "Zorblax Press": .custom
    ]

    init() throws {
        container = try GymStore.container(inMemory: true)
        workouts = WorkoutRepository(context: container.mainContext)
        customs = CustomExerciseRepository(context: container.mainContext)
        service = ImportService(workouts: workouts, customExercises: customs)
    }

    private func allWorkouts() throws -> [Workout] {
        try workouts.recent(limit: 1_000).sorted { $0.startedAt < $1.startedAt }
    }

    @Test func importsEveryWorkoutWithSummary() async throws {
        let summary = try await service.importAll(plan: ImportFixtures.samplePlan(), choices: choices)
        #expect(summary.workouts == 3)
        #expect(summary.sets == 28)
        #expect(summary.warmupSets == 1)
        #expect(summary.rowErrors.map(\.line) == [17])
        #expect(Set(summary.createdExercises.map(\.name)) == ["Clam", "Handle Band Row", "Swimming", "Zorblax Press"])
        let saved = try allWorkouts()
        #expect(saved.count == 3)
        #expect(saved.allSatisfy { $0.source == .import && $0.note == "Imported from Fitbod" })
    }

    @Test func mapsEntriesInOrderWithResolvedIds() async throws {
        _ = try await service.importAll(plan: ImportFixtures.samplePlan(), choices: choices)
        let first = try #require(try allWorkouts().first)
        #expect(first.id == (try ImportFixtures.samplePlan().result.workouts[0].id))
        let clam = try #require(try customs.all().first { $0.name == "Clam" })
        #expect(first.entries.map(\.exerciseId) == ["0025", "0198", clam.id, "0294"])
        let curl = first.entries[3].sets[0]
        #expect(curl.weightKg == 12 && curl.reps == 10 && curl.multiplier == 2 && curl.done)
        #expect(curl.completedAt == first.startedAt)
    }

    @Test func warmupFlagIsPreserved() async throws {
        _ = try await service.importAll(plan: ImportFixtures.samplePlan(), choices: choices)
        let bench = try #require(try allWorkouts().first?.entries.first)
        #expect(bench.sets.map(\.warmup) == [true, false, false, false])
    }

    @Test func cardioRowsBecomeCardioSets() async throws {
        _ = try await service.importAll(plan: ImportFixtures.samplePlan(), choices: choices)
        let saved = try allWorkouts()
        let walk = try #require(saved[1].entries.first)
        #expect(walk.exerciseId == "3666")
        #expect(walk.sets[0].sec == 1_200 && walk.sets[0].distanceM == 1_500 && walk.sets[0].reps == 0)
        let swimming = try #require(try customs.all().first { $0.name == "Swimming" })
        #expect(swimming.mode == .cardio)
        #expect(try customs.all().first { $0.name == "Clam" }?.mode == .reps)
        #expect(saved[2].entries[0].sets.map(\.sec) == [900, 600])
    }

    @Test func endedAtIsApproximate() async throws {
        _ = try await service.importAll(plan: ImportFixtures.samplePlan(), choices: choices)
        let first = try #require(try allWorkouts().first)
        #expect(first.endedAt == first.startedAt.addingTimeInterval(45 * 60))
    }

    @Test func allTimedWorkoutEndsAfterItsDurations() async throws {
        let lib = try ImportFixtures.library()
        let csv = """
        Date,Exercise,Reps,Weight(kg),Duration(s),Distance(m),Incline,Resistance,isWarmup,Note,multiplier
        2026-02-01 08:00:00 +0000,Walking,0,0.0,1200.0,0.0,0.0,0.0,false,,1.0
        2026-02-01 08:00:00 +0000,Walking,0,0.0,600.0,0.0,0.0,0.0,false,,1.0
        """
        let plan = ImportPlan.make(result: try FitbodImporter.parse(csv), library: lib,
                                   aliases: try FitbodAliases.load(), matcher: ExerciseMatcher(library: lib.exercises))
        _ = try await service.importAll(plan: plan, choices: [:])
        let walk = try #require(try allWorkouts().first)
        #expect(walk.endedAt == walk.startedAt.addingTimeInterval(1_800))
    }

    @Test func reimportIsIdempotent() async throws {
        let plan = try ImportFixtures.samplePlan()
        _ = try await service.importAll(plan: plan, choices: choices)
        let second = try await service.importAll(plan: plan, choices: choices)
        #expect(try allWorkouts().count == 3)
        #expect(try customs.all().count == 4)
        #expect(second.createdExercises.isEmpty)
        #expect(try allWorkouts().flatMap(\.entries).flatMap(\.sets).count == 28)
    }

    @Test func customExercisesAreCreatedOnceAcrossWorkouts() async throws {
        _ = try await service.importAll(plan: ImportFixtures.samplePlan(), choices: choices)
        #expect(try customs.all().filter { $0.name == "Clam" }.count == 1)
        let clamId = try #require(try customs.all().first { $0.name == "Clam" }?.id)
        let clamEntries = try allWorkouts().flatMap(\.entries).filter { $0.exerciseId == clamId }
        #expect(clamEntries.count == 2)
    }

    @Test func unresolvedNamesThrowBeforeWriting() async throws {
        await #expect(throws: ImportServiceError.unresolved(["Dumbbell Biceps Curls", "Zorblax Press"])) {
            try await service.importAll(plan: ImportFixtures.samplePlan(), choices: [:])
        }
        #expect(try allWorkouts().isEmpty)
        #expect(try customs.all().isEmpty)
    }

    @Test func progressRisesToOne() async throws {
        var reported: [Double] = []
        _ = try await service.importAll(plan: ImportFixtures.samplePlan(), choices: choices) { reported.append($0) }
        #expect(reported.first == 0)
        #expect(reported.last == 1)
        #expect(reported == reported.sorted())
    }

    // MARK: Dedupe against existing workouts

    @Test func workoutAlreadyInTheLogFromElsewhereIsSkipped() async throws {
        // Same session logged in the app (random id) 30 s after the fixture's first workout starts.
        let first = Date(timeIntervalSince1970: 1_767_636_000)
        try workouts.save(Workout(startedAt: first.addingTimeInterval(30), endedAt: first.addingTimeInterval(3_600),
                                  name: "Push", entries: [WorkoutEntry(exerciseId: "0025", sets: [
                                      WorkoutSet(weightKg: 60, reps: 8, done: true)])]))
        let summary = try await service.importAll(plan: ImportFixtures.samplePlan(), choices: choices)
        #expect(summary.duplicatesSkipped == 1)
        #expect(summary.workouts == 2)
        #expect(summary.sets == 17) // the 11 sets of the skipped workout are not counted
        #expect(summary.warmupSets == 0)
        let saved = try allWorkouts()
        #expect(saved.count == 3)
        #expect(saved.filter { $0.source == .import }.count == 2)
        #expect(saved.first?.name == "Push") // the app's workout is untouched
    }

    @Test func workoutsFartherApartThanTheWindowAreKept() async throws {
        let first = Date(timeIntervalSince1970: 1_767_636_000)
        try workouts.save(Workout(startedAt: first.addingTimeInterval(-ImportService.duplicateWindow - 1),
                                  endedAt: first, name: "Earlier"))
        let summary = try await service.importAll(plan: ImportFixtures.samplePlan(), choices: choices)
        #expect(summary.duplicatesSkipped == 0)
        #expect(summary.workouts == 3)
    }

    @Test func reimportOverwritesInsteadOfCountingDuplicates() async throws {
        let plan = try ImportFixtures.samplePlan()
        _ = try await service.importAll(plan: plan, choices: choices)
        let second = try await service.importAll(plan: plan, choices: choices)
        #expect(second.duplicatesSkipped == 0)
        #expect(second.workouts == 3)
    }

    @Test func dedupeHelperUsesSortedStarts() throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let imported = [0, 100, 1_000].map { offset in
            ImportedWorkout(id: UUID(), startedAt: base.addingTimeInterval(TimeInterval(offset)), entries: [])
        }
        let existing = [base.addingTimeInterval(1_059), base.addingTimeInterval(-60)].map {
            Workout(startedAt: $0, name: "x")
        }
        let (kept, skipped) = try ImportService.withoutDuplicates(imported, existing: existing)
        #expect(skipped == 2)
        #expect(kept.map(\.startedAt) == [base.addingTimeInterval(100)])
    }

    @Test func fitbodWorkoutsKeepTheirNameAndNote() async throws {
        _ = try await service.importAll(plan: ImportFixtures.samplePlan(), choices: choices)
        #expect(try allWorkouts().allSatisfy { $0.name == "Fitbod workout" && $0.note == "Imported from Fitbod" })
    }

    /// Fitbod writes its own multiplier column; the library's equipment must not override it.
    @Test func fitbodKeepsItsExplicitMultiplierWithALibrary() async throws {
        let withLibrary = ImportService(workouts: workouts, customExercises: customs,
                                        library: try ImportFixtures.library())
        _ = try await withLibrary.importAll(plan: ImportFixtures.samplePlan(), choices: choices)
        let bench = try #require(try allWorkouts().first?.entries.first)
        #expect(bench.exerciseId == "0025" && bench.sets.allSatisfy { $0.multiplier == 1 })
        let curl = try #require(try allWorkouts().first?.entries.last)
        #expect(curl.sets.map(\.multiplier) == [2, 2])
    }
}
