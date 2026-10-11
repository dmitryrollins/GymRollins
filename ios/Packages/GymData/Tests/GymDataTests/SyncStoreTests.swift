import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Mutable test clock shared by repositories and the sync store.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    func advance(_ seconds: TimeInterval = 60) { now = now.addingTimeInterval(seconds) }
}

@MainActor
struct SyncFixture {
    let container: ModelContainer
    let clock = TestClock()
    let defaults: UserDefaults
    let suiteName = "test-\(UUID())"

    init() throws {
        container = try GymStore.container(inMemory: true)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    var context: ModelContext { container.mainContext }
    var store: SyncStore { SyncStore(context: context, defaults: defaults, now: { [clock] in clock.now }) }
    var routines: RoutineRepository { RoutineRepository(context: context, now: { [clock] in clock.now }) }
    var workouts: WorkoutRepository { WorkoutRepository(context: context, now: { [clock] in clock.now }) }
    var body: BodyRepository { BodyRepository(context: context, now: { [clock] in clock.now }) }
    var profiles: ProfileRepository { ProfileRepository(context: context, now: { [clock] in clock.now }) }
    var custom: CustomExerciseRepository { CustomExerciseRepository(context: context, now: { [clock] in clock.now }) }

    func tearDown() { defaults.removePersistentDomain(forName: suiteName) }

    func routineRecord(_ id: UUID) throws -> RoutineRecord? {
        try context.fetch(FetchDescriptor<RoutineRecord>(predicate: #Predicate { $0.id == id })).first
    }
}

func sampleRoutine(id: UUID = UUID(), name: String = "Push") -> Routine {
    Routine(id: id, name: name, exercises: [RoutineExercise(exerciseId: "bench", sets: 3, reps: 8, weightKg: 60)])
}

@MainActor
@Suite struct SyncStoreTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    // Rule 1
    @Test func dirtyRowsIncludeTombstones() throws {
        defer { f.tearDown() }
        let r = sampleRoutine()
        try f.routines.upsert(r)
        let bw = BodyweightEntry(date: f.clock.now, weightKg: 81)
        try f.body.add(bw)
        f.clock.advance()
        try f.routines.delete(r.id)
        try f.body.delete(bw.id)

        let routines = try f.store.dirtyRoutines()
        #expect(routines.count == 1)
        #expect(routines.first?.deletedAt == f.clock.now)
        #expect(routines.first?.value.routine == r)
        #expect(try f.store.dirtyBodyweight().first?.deletedAt == f.clock.now)
    }

    // Rule 2
    @Test func markSyncedClearsDirtyAndStoresServerTime() throws {
        defer { f.tearDown() }
        try f.routines.upsert(sampleRoutine())
        let row = try #require(f.store.dirtyRoutines().first)
        let server = f.clock.now.addingTimeInterval(5)
        try f.store.markSynced(.routines, id: row.value.routine.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                               serverUpdatedAt: server)
        #expect(try f.store.dirtyRoutines().isEmpty)
        #expect(try f.routineRecord(row.value.routine.id)?.serverUpdatedAt == server)
    }

    // Rule 2: an edit made while the push was in flight keeps the row dirty.
    @Test func markSyncedKeepsRowDirtyWhenEditedDuringPush() throws {
        defer { f.tearDown() }
        let r = sampleRoutine()
        try f.routines.upsert(r)
        let pushed = try #require(f.store.dirtyRoutines().first)
        f.clock.advance()
        try f.routines.upsert(sampleRoutine(id: r.id, name: "Push B"))
        try f.store.markSynced(.routines, id: r.id.uuidString, clientUpdatedAt: pushed.clientUpdatedAt,
                               serverUpdatedAt: f.clock.now)
        let again = try f.store.dirtyRoutines()
        #expect(again.count == 1)
        #expect(again.first?.value.routine.name == "Push B")
    }

    // Rule 3: inserts new rows and overwrites clean ones.
    @Test func applyRemoteInsertsAndOverwritesCleanRoutines() throws {
        defer { f.tearDown() }
        let existing = sampleRoutine(name: "Old")
        try f.routines.upsert(existing)
        let pushed = try #require(f.store.dirtyRoutines().first)
        try f.store.markSynced(.routines, id: existing.id.uuidString, clientUpdatedAt: pushed.clientUpdatedAt,
                               serverUpdatedAt: f.clock.now)
        let fresh = sampleRoutine(name: "Legs")
        let server = f.clock.now.addingTimeInterval(10)
        try f.store.applyRemote(routines: [
            SyncRow(value: RoutineSnapshot(routine: sampleRoutine(id: existing.id, name: "New"), position: 1),
                    clientUpdatedAt: server, serverUpdatedAt: server),
            SyncRow(value: RoutineSnapshot(routine: fresh, position: 0), clientUpdatedAt: server, serverUpdatedAt: server),
        ])
        let all = try f.routines.all()
        #expect(all.map(\.name) == ["Legs", "New"])
        #expect(try f.routineRecord(fresh.id)?.serverUpdatedAt == server)
    }

    // Rule 3: dirty local rows are left alone (they are re-pushed and win by edit time).
    @Test func applyRemoteLeavesNewerDirtyRoutineAlone() throws {
        defer { f.tearDown() }
        let r = sampleRoutine(name: "Mine")
        try f.routines.upsert(r)
        let olderEdit = f.clock.now.addingTimeInterval(-60)
        try f.store.applyRemote(routines: [
            SyncRow(value: RoutineSnapshot(routine: sampleRoutine(id: r.id, name: "Theirs"), position: 0),
                    clientUpdatedAt: olderEdit, serverUpdatedAt: f.clock.now),
        ])
        #expect(try f.routines.routine(r.id)?.name == "Mine")
        #expect(try f.store.dirtyRoutines().count == 1)
    }

    // Last write wins by edit time: a dirty row older than the remote edit would lose on push, so remote wins.
    @Test func applyRemoteOverwritesOlderDirtyRoutine() throws {
        defer { f.tearDown() }
        let r = sampleRoutine(name: "Mine")
        try f.routines.upsert(r)
        let newerEdit = f.clock.now.addingTimeInterval(60)
        try f.store.applyRemote(routines: [
            SyncRow(value: RoutineSnapshot(routine: sampleRoutine(id: r.id, name: "Theirs"), position: 0),
                    clientUpdatedAt: newerEdit, serverUpdatedAt: newerEdit),
        ])
        #expect(try f.routines.routine(r.id)?.name == "Theirs")
        #expect(try f.store.dirtyRoutines().isEmpty)
    }

    @Test func remoteTombstoneHidesRoutine() throws {
        defer { f.tearDown() }
        let r = sampleRoutine()
        try f.store.applyRemote(routines: [
            SyncRow(value: RoutineSnapshot(routine: r, position: 0), clientUpdatedAt: f.clock.now,
                    serverUpdatedAt: f.clock.now),
        ])
        #expect(try f.routines.all().count == 1)
        f.clock.advance()
        try f.store.applyRemote(routines: [
            SyncRow(value: RoutineSnapshot(routine: r, position: 0), clientUpdatedAt: f.clock.now,
                    deletedAt: f.clock.now, serverUpdatedAt: f.clock.now),
        ])
        #expect(try f.routines.all().isEmpty)
        #expect(try f.store.dirtyRoutines().isEmpty)
    }

    // Rule 4
    @Test func applyingRemoteRowsNeverMarksDirty() throws {
        defer { f.tearDown() }
        let t = f.clock.now
        var profile = ProfileSnapshot()
        profile.unit = .kg
        profile.platesKg = [25, 20]
        profile.mcpReadPlan = false
        try f.store.applyRemote(profile: SyncRow(value: profile, clientUpdatedAt: t, serverUpdatedAt: t))
        let ex = Exercise(id: "custom-x", name: "Sled", bodyPart: "legs", equipment: "sled", target: "quads",
                          isCustom: true, mode: .reps, bilateral: true)
        try f.store.applyRemote(customExercises: [SyncRow(value: ex, clientUpdatedAt: t, serverUpdatedAt: t)])
        let r = sampleRoutine()
        try f.store.applyRemote(routines: [SyncRow(value: RoutineSnapshot(routine: r, position: 0), clientUpdatedAt: t,
                                                   serverUpdatedAt: t)])
        try f.store.applyRemote(weekdays: [SyncRow(value: WeekdayAssignment(weekday: 1, routineId: r.id),
                                                   clientUpdatedAt: t, serverUpdatedAt: t)])
        let bw = BodyweightEntry(date: t, weightKg: 82, bodyFatPct: 14, timeOfDay: "morning")
        try f.store.applyRemote(bodyweight: [SyncRow(value: bw, clientUpdatedAt: t, serverUpdatedAt: t)])

        #expect(try f.store.dirtyProfile() == nil)
        #expect(try f.store.dirtyCustomExercises().isEmpty)
        #expect(try f.store.dirtyRoutines().isEmpty)
        #expect(try f.store.dirtyWeekdays().isEmpty)
        #expect(try f.store.dirtyBodyweight().isEmpty)
        #expect(try f.profiles.load().unit == .kg)
        #expect(try f.profiles.load().mcpReadPlan == false)
        #expect(try f.custom.all() == [ex])
        #expect(try f.routines.schedule().days == [1: r.id])
        #expect(try f.body.entries(since: nil) == [bw])
    }

    @Test func dirtyProfileWeekdaysAndCustomExercisesRoundTrip() throws {
        defer { f.tearDown() }
        try f.profiles.save(Profile(unit: .kg, goalWeightKg: 85))
        let r = sampleRoutine()
        try f.routines.setSchedule(weekday: 3, routineId: r.id)
        let ex = try f.custom.create(name: "Sled", bodyPart: "legs", equipment: "sled", target: "quads", mode: .reps,
                                     bilateral: false)

        let profile = try #require(try f.store.dirtyProfile())
        #expect(profile.value.unit == .kg)
        #expect(profile.value.goalWeightKg == 85)
        #expect(profile.clientUpdatedAt == f.clock.now)
        #expect(try f.store.dirtyWeekdays().map(\.value) == [WeekdayAssignment(weekday: 3, routineId: r.id)])
        #expect(try f.store.dirtyCustomExercises().map(\.value) == [ex])

        try f.store.markSynced(.profile, id: SyncStore.profileSyncID, clientUpdatedAt: profile.clientUpdatedAt,
                               serverUpdatedAt: f.clock.now)
        try f.store.markSynced(.weekSchedule, id: "3", clientUpdatedAt: f.clock.now, serverUpdatedAt: f.clock.now)
        try f.store.markSynced(.customExercises, id: ex.id, clientUpdatedAt: f.clock.now, serverUpdatedAt: f.clock.now)
        #expect(try f.store.dirtyProfile() == nil)
        #expect(try f.store.dirtyWeekdays().isEmpty)
        #expect(try f.store.dirtyCustomExercises().isEmpty)
    }

    @Test func strengthProfileMarksDirtyAndAppliesFromRemote() throws {
        defer { f.tearDown() }
        try f.profiles.setStrengthProfile(sex: .female, birthYear: 1990)
        let row = try #require(try f.store.dirtyProfile())
        #expect(row.value.sex == .female)
        #expect(row.value.birthYear == 1990)

        var remote = row.value
        remote.sex = .male
        remote.birthYear = nil
        f.clock.advance(60)
        try f.store.applyRemote(profile: SyncRow(value: remote, clientUpdatedAt: f.clock.now,
                                                 serverUpdatedAt: f.clock.now))
        let loaded = try f.profiles.load()
        #expect(loaded.sex == .male)
        #expect(loaded.birthYear == nil)
    }

    // Rule 6 + cursors
    @Test func cursorsPersistAndResetAllWipesEverything() throws {
        defer { f.tearDown() }
        #expect(f.store.cursor(for: .routines) == nil)
        f.store.setCursor(f.clock.now, for: .routines)
        #expect(f.store.cursor(for: .routines) == f.clock.now)
        #expect(f.store.cursor(for: .workouts) == nil)

        try f.routines.upsert(sampleRoutine())
        try f.body.add(BodyweightEntry(date: f.clock.now, weightKg: 81))
        try f.profiles.save(Profile())
        try f.workouts.save(Workout(startedAt: f.clock.now, name: "W"))
        try f.store.resetAll()

        #expect(f.store.cursor(for: .routines) == nil)
        #expect(try f.context.fetchCount(FetchDescriptor<RoutineRecord>()) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<RoutineExerciseRecord>()) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<BodyweightRecord>()) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<ProfileRecord>()) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<WorkoutRecord>()) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<SetRecord>()) == 0)
    }
}
