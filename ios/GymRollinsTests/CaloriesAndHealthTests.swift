import Foundation
import GymCore
import GymData
import GymHealth
import Testing
@testable import GymRollins

/// Plan 15: the bundled Compendium values, the app's calorie service and the Health wiring.
@MainActor
@Suite struct CaloriesAndHealthTests {
    /// The published 2024 Adult Compendium values (pacompendium.com, 2026-09-30). Never change these: the terms say
    /// "Please do not change MET values".
    private static let published: [String: Double] = [
        "01200": 6.8, "02020": 7.5, "02022": 3.8, "02024": 2.8, "02034": 3.5, "02035": 5.0, "02040": 7.5,
        "02048": 5.0, "02049": 9.0, "02050": 6.0, "02052": 5.0, "02054": 3.5, "02055": 5.8, "02060": 5.5,
        "02065": 9.3, "02068": 11.0, "02070": 7.3, "02071": 5.0, "02080": 6.8, "02115": 2.8, "02210": 7.0,
        "02214": 11.0, "12150": 8.0, "17035": 7.0, "17200": 4.8,
    ]

    @Test func bundledMETValuesAreThePublishedOnes() throws {
        let table = try #require(CalorieService.loadTable())
        #expect(Dictionary(uniqueKeysWithValues: table.activities.map { ($0.code, $0.met) }) == Self.published)
        #expect(Set(CalorieActivity.allCodes) == Set(Self.published.keys))
        #expect(table.source.citation.contains("Herrmann SD"))
        #expect(table.source.terms.contains { $0.contains("do not change MET values") })
        #expect(table.activities.allSatisfy { !$0.description.isEmpty })
    }

    @Test func estimateUsesTheWeighInBeforeTheWorkout() throws {
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow",
                                                                       "2026-09-26T09:00:00Z"]))
        let start = env.now().addingTimeInterval(-7_200)
        let workout = Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "Push",
                              entries: [WorkoutEntry(exerciseId: "0025", sets: (0..<10).map { _ in
                                  WorkoutSet(weightKg: 60, reps: 8, done: true, rpe: 9)
                              })])
        let none = try #require(env.calories.estimate(workout))
        #expect(none.usedDefaultBodyWeight)

        try env.body.add(BodyweightEntry(date: start.addingTimeInterval(-86_400), weightKg: 80))
        try env.body.add(BodyweightEntry(date: start.addingTimeInterval(86_400), weightKg: 90))
        env.dataChanged()
        let estimate = try #require(env.calories.estimate(workout))
        #expect(estimate.bodyWeightKg == 80)
        #expect(estimate.kcal == 480) // 02050 vigorous: 6.0 MET × 80 kg × 1 h
    }

    @Test func weekTotalSumsThisWeeksWorkouts() throws {
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow",
                                                                       "2026-09-26T09:00:00Z"]))
        let make = { (daysAgo: Double) in
            let start = env.now().addingTimeInterval(-daysAgo * 86_400)
            return Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "W",
                           entries: [WorkoutEntry(exerciseId: "0025", sets: (0..<10).map { _ in
                               WorkoutSet(weightKg: 60, reps: 8, done: true, rpe: 9)
                           })])
        }
        // Sat 26 Sep: Thu and Fri count, last Saturday doesn't.
        let total = env.calories.weekTotal(of: [make(1), make(2), make(7)], containing: env.now())
        #expect(total == 2 * 420) // default 70 kg × 6.0 MET
    }

    @Test func fakeHealthFlagUsesTheFakeStoreAndImportsOnEnable() async throws {
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fakeHealth", "-fixedNow",
                                                                       "2026-09-26T09:00:00Z"]))
        #expect(env.health.isAvailable)
        #expect(!env.health.isEnabled) // a UI-test launch always starts with Health off
        #expect(await env.health.enable())
        let imported = try env.body.entries(since: nil).filter { $0.source == .appleHealth }
        #expect(imported.map(\.weightKg) == [81.0, 81.3, 81.6])
        #expect(imported.first { $0.weightKg == 81.3 }?.bodyFatPct == 15.2)
    }

    @Test func finishingAWorkoutSavesItToHealth() async throws {
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fakeHealth", "-fixedNow",
                                                                       "2026-09-26T09:00:00Z",
                                                                       "-workoutStartedMinutesAgo", "45"]))
        _ = await env.health.enable()
        env.startSession(routine: try env.routines.all().first)
        let session = try #require(env.session)
        #expect(abs(session.workout.startedAt.timeIntervalSince(env.now()) + 45 * 60) < 1)
        session.markAllDone()
        _ = try session.finish(discardingUndone: false)
        env.dataChanged()
        await env.health.exportChanges()
        #expect(env.health.exportStatus(for: session.workout) == .saved)
        #expect(try #require(env.calories.estimate(session.workout)).kcal > 0)
    }

    @Test func erasingAllDataTurnsHealthOff() async throws {
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fakeHealth"]))
        _ = await env.health.enable()
        try env.eraseAllLocalData()
        #expect(!env.health.isEnabled)
    }
}

@MainActor
@Suite struct HealthImportGateTests {
    /// Codex round 7: the Health import waits until launch restored the session; without a backend there's none to
    /// wait for.
    @Test func noBackendMeansNothingToWaitFor() throws {
        let store = try SyncStore(context: GymStore.container(inMemory: true).mainContext,
                                  defaults: #require(UserDefaults(suiteName: "gate.\(UUID())")), now: Date.init)
        let offline = SyncCoordinator(auth: nil, store: store, now: Date.init, makeTransport: { _ in nil })
        #expect(offline.hasRestoredSession)
    }
}
