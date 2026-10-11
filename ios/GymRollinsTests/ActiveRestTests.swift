import Foundation
import GymCore
import Testing
@testable import GymRollins

/// The running rest survives the app being terminated (the Live Activity outlives the process, and a cold-start
/// intent must still see the rest it shows).
@MainActor
@Suite struct ActiveRestTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ActiveRestTests.\(UUID())"))
    }

    @Test func storeRoundTripsPerWorkout() throws {
        let store = ActiveRestStore(defaults: try defaults())
        let workout = UUID()
        let rest = RestTimer(startedAt: Date(timeIntervalSince1970: 1_000), duration: 90)
        #expect(store.load(workoutId: workout) == nil)
        store.save(rest, workoutId: workout)
        #expect(store.load(workoutId: workout) == rest)
        #expect(store.load(workoutId: UUID()) == nil)
        store.save(nil, workoutId: workout)
        #expect(store.load(workoutId: workout) == nil)
    }

    @Test func sessionReportsEveryRestChange() {
        var saved: [RestTimer?] = []
        var now = Date(timeIntervalSince1970: 1_000)
        let workout = Workout(startedAt: now, name: "W", entries: [
            WorkoutEntry(exerciseId: "x", sets: [WorkoutSet(weightKg: 60, reps: 8), WorkoutSet(weightKg: 60, reps: 8)])
        ])
        let s = WorkoutSession(
            workout: workout, clock: WorkoutClock(startedAt: now), restSeconds: 90, warmupRestSeconds: 60,
            notifier: NoopRestNotifier(), now: { now }, persist: { _, _ in }, previousBests: { _ in nil },
            saveFinished: { _, _ in }, discard: {}, persistRest: { saved.append($0) })
        s.logNextSet(entryId: workout.entries[0].id, weightKg: 60, reps: 8)
        s.adjustRest(by: 30)
        s.skipRest()
        #expect(saved == [RestTimer(startedAt: now, duration: 90), RestTimer(startedAt: now, duration: 120), nil])
        s.logNextSet(entryId: workout.entries[0].id, weightKg: 60, reps: 8) // last set: no rest
        now = now.addingTimeInterval(10)
        #expect(saved.count == 3)
    }

    @Test func restoredSessionKeepsTheRunningRest() throws {
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]), defaults: try defaults())
        env.startSession(routine: try env.routines.all().first)
        let session = try #require(env.session)
        let entry = try #require(session.workout.entries.first)
        session.logNextSet(entryId: entry.id, weightKg: entry.sets[0].weightKg, reps: entry.sets[0].reps)
        let rest = try #require(session.rest)

        env.endSession()
        env.restoreSession()
        #expect(env.session?.rest == rest)
        #expect(env.session !== session)
    }

    @Test func anExpiredRestIsNotRestored() throws {
        // Restoring it would count as a rest that just ran out (haptic + "Rest over" on relaunch).
        let defaults = try defaults()
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]),
                                     defaults: defaults)
        env.startSession(routine: nil)
        let workoutId = try #require(env.session?.workout.id)
        ActiveRestStore(defaults: defaults).save(RestTimer(startedAt: env.now().addingTimeInterval(-300), duration: 90),
                                                 workoutId: workoutId)
        env.endSession()
        env.restoreSession()
        #expect(env.session?.rest == nil)
        #expect(env.session?.restCompletions == 0)
    }
}
