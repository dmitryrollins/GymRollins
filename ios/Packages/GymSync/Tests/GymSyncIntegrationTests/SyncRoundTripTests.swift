import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// Full `SyncEngine` rounds: real in-memory SwiftData stores, `SupabaseTransport`, local Supabase.
@MainActor
@Suite(.enabled(if: supabaseConfigured, "Set SUPABASE_URL and SUPABASE_ANON_KEY to run against local Supabase"))
struct SyncRoundTripTests {
    /// Everything pushed from one device arrives unchanged on a second, fresh device of the same user.
    @Test func secondDevicePullsEverythingTheFirstPushed() async throws {
        let user = try await Account.signUp()
        let phone = try Device(user, clock: DeviceClock("2026-09-27T07:30:00.654321Z"))
        defer { phone.tearDown() }

        try phone.profiles.save(Profile(unit: .kg, restSec: 150, heightCm: 181.5, goalWeightKg: 85,
                                        goalDate: SyncDay.parse("2026-12-31"), trainingDays: 4,
                                        limits: "left shoulder", deloadPct: 0.1))
        let routine = Routine(name: "Push", emoji: "💪", policy: .double, exercises: [
            RoutineExercise(exerciseId: "bench", sets: 3, reps: 8, repsMin: 6, weightKg: 61.234567, policy: .linear,
                            incKg: 2.267962, weightSetAt: phone.clock.now),
            RoutineExercise(exerciseId: "plank", sets: 3, reps: 0, sec: 60, mode: .time),
        ])
        try phone.routines.upsert(routine)
        try phone.routines.setSchedule(weekday: 2, routineId: routine.id)
        let weighIn = BodyweightEntry(date: phone.clock.now, weightKg: 81.4, bodyFatPct: 15.5, timeOfDay: "am")
        try phone.body.add(weighIn)
        try phone.prefs.set(.more, for: "0025")
        try phone.prefs.set(.never, for: "0070")
        let workout = finishedWorkout(name: "Push", at: phone.clock.now)
        try phone.workouts.save(workout, records: benchRecords)

        await phone.engine.sync()
        #expect(phone.engine.status == .idle)
        #expect(try phone.store.dirtyWorkouts().isEmpty)
        #expect(try phone.store.dirtyRoutines().isEmpty)
        #expect(try phone.store.dirtyProfile() == nil)
        #expect(try phone.store.dirtyExercisePreferences().isEmpty)

        let ipad = try Device(try await user.onAnotherDevice(), clock: DeviceClock("2026-09-27T09:00:00Z"))
        defer { ipad.tearDown() }
        await ipad.engine.sync()

        #expect(ipad.engine.status == .idle)
        #expect(try ipad.profiles.load() == phone.profiles.load())
        #expect(try ipad.routines.all() == [routine])
        #expect(try ipad.routines.schedule() == phone.routines.schedule())
        #expect(try ipad.body.entries(since: nil) == [weighIn])
        #expect(try ipad.prefs.all() == ["0025": .more, "0070": .never])
        #expect(try ipad.workouts.workout(workout.id) == workout)
        #expect(try ipad.workouts.records(for: workout.id) == benchRecords)
        #expect(try ipad.store.dirtyWorkouts().isEmpty)

        // A second round on either device moves nothing: cursors advanced past the echoed rows.
        await phone.engine.sync()
        await ipad.engine.sync()
        #expect(phone.engine.status == .idle)
        #expect(ipad.engine.status == .idle)

        try await user.deleteAccount()
    }

    /// The older edit of a workout is answered `stale` and surfaces as a conflict; keeping local wins afterwards.
    @Test func staleWorkoutBecomesConflictAndKeepLocalWins() async throws {
        let user = try await Account.signUp()
        let phone = try Device(user, clock: DeviceClock("2026-09-27T07:00:00.100000Z"))
        defer { phone.tearDown() }
        let original = finishedWorkout(name: "Original", at: phone.clock.now)
        try phone.workouts.save(original)
        await phone.engine.sync()

        let ipad = try Device(try await user.onAnotherDevice(), clock: DeviceClock("2026-09-27T07:10:00Z"))
        defer { ipad.tearDown() }
        await ipad.engine.sync()
        try ipad.workouts.save(finishedWorkout(id: original.id, name: "iPad edit", at: original.startedAt))
        await ipad.engine.sync()
        #expect(ipad.engine.status == .idle)

        phone.clock.advance(300)  // 07:05 — edited before the iPad's 07:10 edit
        try phone.workouts.save(finishedWorkout(id: original.id, name: "Phone edit", at: original.startedAt))
        await phone.engine.sync()
        #expect(phone.engine.status == .conflicts([original.id]))
        #expect(try phone.workouts.workout(original.id)?.name == "Phone edit")  // local untouched
        #expect(try await user.transport.fetchWorkout(id: original.id)?.name == "iPad edit")

        phone.clock.advance(900)  // the owner resolves later
        await phone.engine.resolve(conflict: original.id, keepLocal: true)
        #expect(phone.engine.status == .idle)
        #expect(try await user.transport.fetchWorkout(id: original.id)?.name == "Phone edit")

        await ipad.engine.sync()
        #expect(try ipad.workouts.workout(original.id)?.name == "Phone edit")

        try await user.deleteAccount()
    }

    /// Codex P1: the phone edits AFTER the iPad (newer edit time) but from the version before the iPad's edit. The
    /// server answers stale (base version mismatch) instead of silently replacing the iPad's edit; only the explicit
    /// "Keep this iPhone's" (force) overwrites it.
    @Test func newerEditOnStaleBaseIsAConflictUntilKeptExplicitly() async throws {
        let user = try await Account.signUp()
        let phone = try Device(user, clock: DeviceClock("2026-09-27T07:00:00.100000Z"))
        defer { phone.tearDown() }
        let original = finishedWorkout(name: "Original", at: phone.clock.now)
        try phone.workouts.save(original)
        await phone.engine.sync()

        let ipad = try Device(try await user.onAnotherDevice(), clock: DeviceClock("2026-09-27T07:10:00Z"))
        defer { ipad.tearDown() }
        await ipad.engine.sync()
        try ipad.workouts.save(finishedWorkout(id: original.id, name: "iPad edit", at: original.startedAt))
        await ipad.engine.sync()
        #expect(ipad.engine.status == .idle)

        phone.clock.advance(1_200) // 07:20 — after the iPad's edit, but the phone never saw it
        try phone.workouts.save(finishedWorkout(id: original.id, name: "Phone edit", at: original.startedAt))
        await phone.engine.sync()
        #expect(phone.engine.status == .conflicts([original.id]))
        #expect(try await user.transport.fetchWorkout(id: original.id)?.name == "iPad edit")
        #expect(try phone.workouts.workout(original.id)?.name == "Phone edit")

        await phone.engine.resolve(conflict: original.id, keepLocal: true)
        #expect(phone.engine.status == .idle)
        #expect(try await user.transport.fetchWorkout(id: original.id)?.name == "Phone edit")
        await ipad.engine.sync()
        #expect(try ipad.workouts.workout(original.id)?.name == "Phone edit")

        try await user.deleteAccount()
    }

    /// RLS: a second user syncs nothing of the first user's data and can't overwrite it.
    @Test func anotherUserSeesAndOverwritesNothing() async throws {
        let owner = try await Account.signUp()
        let phone = try Device(owner, clock: DeviceClock("2026-09-27T07:00:00Z"))
        defer { phone.tearDown() }
        let routine = Routine(name: "Legs", exercises: [RoutineExercise(exerciseId: "squat", sets: 5, reps: 5)])
        try phone.routines.upsert(routine)
        try phone.routines.setSchedule(weekday: 1, routineId: routine.id)
        try phone.body.add(BodyweightEntry(date: phone.clock.now, weightKg: 80))
        let workout = finishedWorkout(name: "Legs", at: phone.clock.now)
        try phone.workouts.save(workout)
        try phone.profiles.save(Profile(unit: .kg))
        await phone.engine.sync()
        #expect(phone.engine.status == .idle)

        let stranger = try await Account.signUp()
        let theirs = try Device(stranger, clock: DeviceClock("2026-09-28T07:00:00Z"))
        defer { theirs.tearDown() }
        await theirs.engine.sync()
        #expect(theirs.engine.status == .idle)
        #expect(try theirs.routines.all().isEmpty)
        #expect(try theirs.workouts.recent(limit: 10).isEmpty)
        #expect(try theirs.body.entries(since: nil).isEmpty)
        #expect(try theirs.routines.schedule().days.isEmpty)
        let t = stranger.transport
        #expect(try await t.pullProfile(since: nil).isEmpty)
        #expect(try await t.pullRoutines(since: nil).isEmpty)
        #expect(try await t.pullWeekdays(since: nil).isEmpty)
        #expect(try await t.pullBodyweight(since: nil).isEmpty)
        #expect(try await t.pullWorkouts(since: nil).isEmpty)
        #expect(try await t.fetchWorkout(id: workout.id) == nil)

        // Writing onto the owner's ids is rejected (RLS / RPC ownership check) and changes nothing.
        let hijack = Routine(id: routine.id, name: "Hijacked")
        let hijackAcks = try? await t.push(routines: [RoutineDTO(SyncRow(value: RoutineSnapshot(routine: hijack,
                                                                                                position: 0),
                                                                          clientUpdatedAt: theirs.clock.now))])
        #expect(hijackAcks?.isEmpty ?? true)
        let hijackWorkout = WorkoutDTO(SyncRow(value: WorkoutSnapshot(workout: finishedWorkout(id: workout.id,
                                                                                              name: "Hijacked",
                                                                                              at: theirs.clock.now),
                                                                      records: [], volumeKg: 0),
                                               clientUpdatedAt: theirs.clock.now))
        await #expect(throws: (any Error).self) { try await t.push(workout: hijackWorkout) }
        #expect(try await owner.transport.pullRoutines(since: nil).map(\.name) == ["Legs"])
        #expect(try await owner.transport.fetchWorkout(id: workout.id)?.name == "Legs")

        try await stranger.deleteAccount()
        try await owner.deleteAccount()
    }
}
