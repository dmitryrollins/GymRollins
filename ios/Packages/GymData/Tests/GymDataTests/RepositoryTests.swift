import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

@MainActor
@Suite struct RepositoryTests {
    let container: ModelContainer
    let clock: () -> Date = { Date(timeIntervalSince1970: 1_790_000_000) }

    init() throws { container = try GymStore.container(inMemory: true) }

    @Test func profileDefaultsAndSave() throws {
        let repo = ProfileRepository(context: container.mainContext, now: clock)
        #expect(try repo.load().unit == .lb)
        try repo.save(Profile(unit: .kg, goalWeightKg: 85))
        let loaded = try repo.load()
        #expect(loaded.unit == .kg)
        #expect(loaded.goalWeightKg == 85)
    }

    /// Sex and birth year are written only by `setStrengthProfile`: a screen that rebuilds and saves the whole
    /// profile (onboarding, bar & plates, …) can't clear them.
    @Test func strengthProfileSurvivesFullSavesAndValidatesBirthYear() throws {
        let repo = ProfileRepository(context: container.mainContext, now: clock)
        #expect(try repo.load().sex == nil)
        #expect(try repo.load().birthYear == nil)
        try repo.setStrengthProfile(sex: .male, birthYear: 1991)
        try repo.save(Profile(unit: .kg, goalWeightKg: 85)) // no sex/birth year in this value
        let loaded = try repo.load()
        #expect(loaded.sex == .male)
        #expect(loaded.birthYear == 1991)
        #expect(loaded.unit == .kg)
        #expect(throws: GymDataError.self) { try repo.setStrengthProfile(sex: .female, birthYear: 1899) }
        #expect(throws: GymDataError.self) { try repo.setStrengthProfile(sex: .female, birthYear: 2101) }
        #expect(try repo.load().sex == .male)
        try repo.setStrengthProfile(sex: nil, birthYear: nil)
        #expect(try repo.load().sex == nil)
        #expect(try repo.load().birthYear == nil)
    }

    /// Plates are stored in kg regardless of display unit, so switching the profile's display unit
    /// never reinterprets the same raw numbers under a different unit.
    @Test func platesAreStoredInKgNotReinterpretedOnUnitSwitch() throws {
        let repo = ProfileRepository(context: container.mainContext, now: clock)
        try repo.save(Profile(unit: .lb, plateInventory: .standardLb))
        try repo.save(Profile(unit: .kg, plateInventory: .standardLb))
        let loaded = try repo.load()
        #expect(loaded.unit == .kg)
        let plates = loaded.plateInventory.plates
        let expected = [20.41, 15.88, 11.34, 4.54, 2.27, 1.13]
        #expect(plates.count == expected.count)
        for (actual, want) in zip(plates, expected) {
            #expect(abs(actual - want) < 0.01)
        }
    }

    @Test func routineUpsertReplacesExercisesAndMarksDirty() throws {
        let repo = RoutineRepository(context: container.mainContext, now: clock)
        let id = UUID()
        try repo.upsert(Routine(id: id, name: "Push", exercises: [RoutineExercise(exerciseId: "0025", sets: 3, reps: 8)]))
        try repo.upsert(Routine(id: id, name: "Push + Arms", exercises: [
            RoutineExercise(exerciseId: "0314", sets: 3, reps: 10),
            RoutineExercise(exerciseId: "0025", sets: 3, reps: 8),
        ]))
        let all = try repo.all()
        #expect(all.count == 1)
        #expect(all[0].name == "Push + Arms")
        #expect(all[0].exercises.map(\.exerciseId) == ["0314", "0025"])
        #expect(try repo.record(id)?.dirty == true)
        #expect(try container.mainContext.fetch(FetchDescriptor<RoutineExerciseRecord>()).count == 2)
    }

    @Test func routineDeleteIsTombstone() throws {
        let repo = RoutineRepository(context: container.mainContext, now: clock)
        let id = UUID()
        try repo.upsert(Routine(id: id, name: "Legs"))
        try repo.delete(id)
        #expect(try repo.all().isEmpty)
        #expect(try repo.record(id)?.deletedAt != nil)
    }

    @Test func scheduleAndRoutineForDate() throws {
        let repo = RoutineRepository(context: container.mainContext, now: clock)
        let push = UUID()
        try repo.upsert(Routine(id: push, name: "Push"))
        try repo.setSchedule(weekday: 6, routineId: push)
        #expect(try repo.schedule().days == [6: push])
        try repo.setSchedule(weekday: 6, routineId: nil)
        #expect(try repo.schedule().days.isEmpty)
    }

    @Test func setScheduleRejectsWeekdayOutOfRange() throws {
        let repo = RoutineRepository(context: container.mainContext, now: clock)
        #expect(throws: GymDataError.invalidInput("ISO weekday 1…7")) {
            try repo.setSchedule(weekday: 0, routineId: nil)
        }
        #expect(throws: GymDataError.invalidInput("ISO weekday 1…7")) {
            try repo.setSchedule(weekday: 8, routineId: nil)
        }
    }

    @Test func workoutSaveHistoryAndBests() throws {
        let repo = WorkoutRepository(context: container.mainContext, now: clock)
        let bench = { (reps: Int, days: Double) in
            Workout(startedAt: Date(timeIntervalSince1970: 1_790_000_000 + days * 86_400), endedAt: nil, name: "Push",
                    entries: [WorkoutEntry(exerciseId: "0025", sets: (0..<3).map { _ in
                        WorkoutSet(weightKg: 58.97, reps: reps, done: true) })])
        }
        try repo.save(bench(6, 0))
        try repo.save(bench(10, 7))
        let history = try repo.history(exerciseId: "0025", limit: 5)
        #expect(history.map(\.reps) == [[10, 10, 10], [6, 6, 6]])
        let bests = try #require(try repo.bests(exerciseId: "0025"))
        #expect(bests.repsAtWeight[weightKey(58.97)] == 10)
        #expect(try repo.recent(limit: 10).count == 2)
    }

    /// Set-level history (every working set, not just the top-weight ones) for e1RM trends.
    @Test func sessionsReturnWholeEntriesNewestFirst() throws {
        let repo = WorkoutRepository(context: container.mainContext, now: clock)
        let day = { (offset: Double) in self.clock().addingTimeInterval(offset * 86_400) }
        try repo.save(Workout(startedAt: day(0), endedAt: day(0), name: "A", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [
                WorkoutSet(weightKg: 100, reps: 1, done: true),
                WorkoutSet(weightKg: 80, reps: 10, done: true)
            ])
        ]))
        try repo.save(Workout(startedAt: day(7), endedAt: day(7), name: "B", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 90, reps: 5, done: true)]),
            WorkoutEntry(exerciseId: "0070", sets: [WorkoutSet(weightKg: 20, reps: 10, done: true)])
        ]))
        try repo.saveActive(Workout(startedAt: day(8), name: "Live", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 200, reps: 1, done: true)])
        ]), pausedAt: nil)
        let sessions = try repo.sessions(exerciseId: "0025", limit: 10)
        #expect(sessions.map(\.date) == [day(7), day(0)])
        #expect(sessions[1].entry.sets.count == 2)
        let e1RM = try #require(WorkoutMetrics.bestE1RM(sessions[1].entry))
        #expect(abs(e1RM - 106.667) < 0.001)
        #expect(try repo.sessions(exerciseId: "0025", limit: 1).count == 1)
    }

    /// The same exercise in two entries of one workout (e.g. in two Hevy supersets) is ONE progression session:
    /// 2 + 2 sets at the top weight, not two separate short sessions that would each look like a miss.
    @Test func repeatedExerciseInOneWorkoutIsOneSession() throws {
        let repo = WorkoutRepository(context: container.mainContext, now: clock)
        let sets = { (count: Int) in (0..<count).map { _ in WorkoutSet(weightKg: 60, reps: 8, done: true) } }
        try repo.save(Workout(startedAt: clock(), endedAt: nil, name: "Push", entries: [
            WorkoutEntry(exerciseId: "0334", sets: sets(2), supersetGroup: "1"),
            WorkoutEntry(exerciseId: "0025", sets: sets(3)),
            WorkoutEntry(exerciseId: "0334", sets: sets(2), supersetGroup: "2"),
        ]))
        let history = try repo.history(exerciseId: "0334", limit: 5)
        #expect(history.count == 1)
        #expect(history.first?.reps == [8, 8, 8, 8])
        #expect(try repo.sessions(exerciseId: "0334", limit: 5).map(\.entry.sets.count) == [4])
    }

    @Test func activeWorkoutExcludedFromHistory() throws {
        let repo = WorkoutRepository(context: container.mainContext, now: clock)
        let workout = Workout(startedAt: clock(), name: "Push", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 60, reps: 8, done: true)])])
        try repo.saveActive(workout, pausedAt: nil)
        #expect(try repo.active()?.id == workout.id)
        #expect(try repo.history(exerciseId: "0025", limit: 5).isEmpty)
        try repo.discardActive()
        #expect(try repo.active() == nil)
    }

    /// Starting a new session while a previous one is still active (never synced) discards the
    /// old active row instead of leaving two `isActive` records behind.
    @Test func savingActiveWithDifferentIdReplacesPreviousActive() throws {
        let repo = WorkoutRepository(context: container.mainContext, now: clock)
        let a = Workout(startedAt: clock(), name: "Push", entries: [])
        let b = Workout(startedAt: clock().addingTimeInterval(60), name: "Pull", entries: [])
        try repo.saveActive(a, pausedAt: nil)
        try repo.saveActive(b, pausedAt: nil)
        #expect(try repo.active()?.id == b.id)
        let activeCount = try container.mainContext.fetchCount(
            FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.isActive }))
        #expect(activeCount == 1)
        let total = try container.mainContext.fetchCount(FetchDescriptor<WorkoutRecord>())
        #expect(total == 1)
    }

    /// Re-saving the same active workout id (e.g. completing a set) updates the existing rows
    /// in place rather than duplicating the workout/entry/set records.
    @Test func savingActiveTwiceWithSameIdReusesRows() throws {
        let repo = WorkoutRepository(context: container.mainContext, now: clock)
        let setId = UUID()
        let entryId = UUID()
        let workoutId = UUID()
        let pending = WorkoutSet(id: setId, weightKg: 60, reps: 8, done: false)
        let first = Workout(id: workoutId, startedAt: clock(), name: "Push",
                            entries: [WorkoutEntry(id: entryId, exerciseId: "0025", sets: [pending])])
        try repo.saveActive(first, pausedAt: nil)

        let completed = pending.completing(at: clock().addingTimeInterval(30))
        let second = Workout(id: workoutId, startedAt: clock(), name: "Push",
                             entries: [WorkoutEntry(id: entryId, exerciseId: "0025", sets: [completed])])
        try repo.saveActive(second, pausedAt: nil)

        #expect(try container.mainContext.fetchCount(FetchDescriptor<WorkoutRecord>()) == 1)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<WorkoutEntryRecord>()) == 1)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<SetRecord>()) == 1)
        let active = try #require(try repo.active())
        #expect(active.entries[0].sets[0].done == true)
        #expect(active.entries[0].sets[0].completedAt == clock().addingTimeInterval(30))
    }

    @Test func recordsRoundTrip() throws {
        let repo = WorkoutRepository(context: container.mainContext, now: clock)
        let w = Workout(startedAt: clock(), endedAt: clock().addingTimeInterval(3_600), name: "Push")
        let pr = PersonalRecord(exerciseId: "0025", kind: .e1RM, valueKg: 78.6, reps: nil, weightKg: nil,
                                previousKg: 70.8)
        try repo.save(w, records: [pr])
        #expect(try repo.records(for: w.id) == [pr])
        #expect(try repo.recordCounts(ids: [w.id]) == [w.id: 1])
    }

    /// Re-saving a workout without records (e.g. editing it later) must not erase records that were
    /// persisted at finish time.
    @Test func resavingWithoutRecordsKeepsExisting() throws {
        let repo = WorkoutRepository(context: container.mainContext, now: clock)
        let w = Workout(startedAt: clock(), endedAt: clock().addingTimeInterval(3_600), name: "Push")
        let pr = PersonalRecord(exerciseId: "0025", kind: .e1RM, valueKg: 78.6, reps: nil, weightKg: nil,
                                previousKg: 70.8)
        try repo.save(w, records: [pr])
        try repo.save(w)
        #expect(try repo.records(for: w.id) == [pr])
    }

    @Test func workoutDeleteIsTombstone() throws {
        let repo = WorkoutRepository(context: container.mainContext, now: clock)
        let workout = Workout(startedAt: clock(), name: "Push", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 60, reps: 8, done: true)])])
        try repo.save(workout)
        try repo.delete(workout.id)
        #expect(try repo.recent(limit: 10).isEmpty)
        #expect(try repo.history(exerciseId: "0025", limit: 5).isEmpty)
        #expect(try repo.workout(workout.id) == nil)
    }

    @Test func bodyweightEntries() throws {
        let repo = BodyRepository(context: container.mainContext, now: clock)
        try repo.add(BodyweightEntry(date: clock(), weightKg: 81))
        try repo.add(BodyweightEntry(date: clock().addingTimeInterval(7 * 86_400), weightKg: 81.4))
        #expect(try repo.latest()?.weightKg == 81.4)
        #expect(try repo.entries(since: nil).map(\.weightKg) == [81, 81.4])
    }

    @Test func bodyweightDeleteIsTombstone() throws {
        let repo = BodyRepository(context: container.mainContext, now: clock)
        let entry = BodyweightEntry(date: clock(), weightKg: 81)
        try repo.add(entry)
        try repo.add(BodyweightEntry(date: clock().addingTimeInterval(7 * 86_400), weightKg: 81.4))
        try repo.delete(entry.id)
        #expect(try repo.entries(since: nil).map(\.weightKg) == [81.4])
        #expect(try repo.latest()?.weightKg == 81.4)
    }

    @Test func customExercises() throws {
        let repo = CustomExerciseRepository(context: container.mainContext, now: clock)
        let ex = try repo.create(name: "Handle Band Squat to Press", bodyPart: "upper legs", equipment: "band",
                                 target: "quads", mode: .reps, bilateral: false)
        #expect(ex.isCustom)
        #expect(ex.id.hasPrefix("custom-"))
        #expect(try repo.all().map(\.name) == ["Handle Band Squat to Press"])
    }

    @Test func customExerciseCarriesBilateralThroughCreateAndAll() throws {
        let repo = CustomExerciseRepository(context: container.mainContext, now: clock)
        let ex = try repo.create(name: "Single Arm Dumbbell Row", bodyPart: "back", equipment: "dumbbell",
                                 target: "lats", mode: .reps, bilateral: false)
        #expect(ex.bilateral == false)
        let bilateralEx = try repo.create(name: "Barbell Bench Press Variant", bodyPart: "chest",
                                          equipment: "barbell", target: "pectorals", mode: .reps, bilateral: true)
        #expect(bilateralEx.bilateral == true)
        #expect(try repo.all().first { $0.id == bilateralEx.id }?.bilateral == true)
        #expect(try repo.all().first { $0.id == ex.id }?.bilateral == false)
    }

    @Test func customExerciseRejectsEmptyName() throws {
        let repo = CustomExerciseRepository(context: container.mainContext, now: clock)
        #expect(throws: GymDataError.invalidInput("Name required")) {
            try repo.create(name: "   ", bodyPart: "upper legs", equipment: "band", target: "quads", mode: .reps,
                            bilateral: false)
        }
        #expect(try repo.all().isEmpty)
    }

    /// Entries are read from the `entriesData` cache written with them; a row without it (written before the cache
    /// existed) reads the same workout from the entry/set rows, and a re-save replaces both.
    @Test func entriesCacheMatchesRowsAndFallsBack() throws {
        let context = container.mainContext
        let repo = WorkoutRepository(context: context, now: clock)
        let workout = Workout(startedAt: clock(), endedAt: clock().addingTimeInterval(600), name: "Push", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 60, reps: 8, done: true),
                                                     WorkoutSet(weightKg: 62.5, reps: 6, done: true)]),
            WorkoutEntry(exerciseId: "0314", sets: [WorkoutSet(weightKg: 20, reps: 12, warmup: true)]),
        ])
        try repo.save(workout)
        let record = try #require(try context.fetch(FetchDescriptor<WorkoutRecord>()).first)
        #expect(record.entriesData != nil)
        #expect(try repo.workout(workout.id) == workout)

        record.entriesData = nil
        #expect(try repo.workout(workout.id) == workout)
        #expect(try repo.history(exerciseId: "0025", limit: 5).count == 1)

        let edited = Workout(id: workout.id, startedAt: workout.startedAt, endedAt: workout.endedAt, name: "Push",
                             entries: [workout.entries[0]])
        try repo.save(edited)
        #expect(record.entriesData != nil)
        #expect(try repo.workout(workout.id)?.entries == edited.entries)
        #expect(try repo.recent(limit: 5).first?.entries == edited.entries)
        #expect(try repo.bests(exerciseId: "0314") == nil)
    }
}
