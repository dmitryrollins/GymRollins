import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@MainActor
@Suite struct LimitsEnvironmentTests {
    private func makeEnv(_ extra: [String] = []) throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: "LimitsEnvironmentTests.\(UUID())"))
        return try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow", "2026-11-01T09:00:00Z"]
                                                         + extra), defaults: defaults)
    }

    private func lb(_ kg: Double?) -> Double { UnitConverter.fromKg(kg ?? .nan, to: .lb) }

    private func legsRoutine(_ env: AppEnvironment) throws -> Routine {
        try #require(try env.routines.all().first { $0.name == "Legs" })
    }

    @Test func theSeededNoteHasNoDateSoNothingIsDue() throws {
        let env = try makeEnv()
        #expect(env.profile.limitsUntil == nil)
        #expect(!env.limitsCheckInDue())
    }

    @Test func seedLimitsDueEndsTheNoteYesterday() throws {
        let env = try makeEnv(["-seedLimitsDue"])
        let today = Calendar.current.startOfDay(for: env.now())
        #expect(env.profile.limits == "Knee: no leg loading")
        #expect(env.profile.limitsUntil == Calendar.current.date(byAdding: .day, value: -1, to: today))
        #expect(env.limitsCheckInDue())
    }

    @Test func notYetMovesTheDateAndStopsAsking() throws {
        let env = try makeEnv(["-seedLimitsDue"])
        let later = LimitsCheckIn.laterDate(now: env.now(), calendar: .current)
        try env.postponeLimits(to: later)
        #expect(env.profile.limits == "Knee: no leg loading")
        #expect(env.profile.limitsUntil == later)
        #expect(!env.limitsCheckInDue())
    }

    @Test func yesClearsTheNoteAndItsDate() throws {
        let env = try makeEnv(["-seedLimitsDue"])
        try env.clearLimits()
        #expect(env.profile.limits == "")
        #expect(env.profile.limitsUntil == nil)
        #expect(!env.limitsCheckInDue())
    }

    @Test func anEmptyNoteKeepsNoDate() throws {
        let env = try makeEnv()
        try env.saveLimits("   ", until: LimitsCheckIn.laterDate(now: env.now(), calendar: .current))
        #expect(env.profile.limits == "")
        #expect(env.profile.limitsUntil == nil)
    }

    @Test func thePausedRoutinesAreTheOnesToOffer() throws {
        let env = try makeEnv()
        #expect(try env.pausedRoutines().map(\.name) == ["Legs"])
    }

    @Test func resumeBringsLegsBackAtSixtyPercent() throws {
        let env = try makeEnv()
        let result = try #require(try env.resumeAtReturnWeights(try legsRoutine(env).id))
        #expect(result.name == "Legs")
        #expect(result.lowered == 6)
        let legs = try legsRoutine(env)
        #expect(!legs.paused)
        let weights = Dictionary(uniqueKeysWithValues: legs.exercises.map { ($0.exerciseId, lb($0.weightKg)) })
        let expected: [String: Double] = ["0085": 80, "0043": 80, "0739": 100, "0586": 60, "0585": 65, "0594": 115]
        for (id, light) in expected { #expect(abs((weights[id] ?? 0) - light) < 0.01, "\(id)") }
        #expect(legs.exercises.allSatisfy { $0.weightSetAt == env.now() })
        #expect(try env.pausedRoutines().isEmpty)
    }

    @Test func theFirstSessionBackIsLightAndProgressionCarriesOnFromIt() throws {
        let env = try makeEnv()
        _ = try env.resumeAtReturnWeights(try legsRoutine(env).id)
        let legs = try legsRoutine(env)
        let squat = try #require(legs.exercises.first { $0.exerciseId == "0043" })
        let suggest = { (history: [SessionResult]) in
            SessionPlanner.suggestion(for: squat, policy: squat.policy ?? legs.policy, profile: env.profile,
                                      exercise: env.library.exercise("0043"), history: history)
        }
        let first = suggest(try env.workouts.history(exerciseId: "0043", limit: 5))
        #expect(abs(lb(first.weightKg) - 80) < 0.01)

        let start = env.now().addingTimeInterval(3_600)
        try env.workouts.save(Workout(startedAt: start, endedAt: start.addingTimeInterval(3_000), name: "Legs", entries: [
            WorkoutEntry(exerciseId: "0043", sets: (0..<4).map { _ in
                WorkoutSet(weightKg: first.weightKg, reps: 6, done: true, completedAt: start) }),
        ]))
        let next = suggest(try env.workouts.history(exerciseId: "0043", limit: 5))
        #expect(abs(lb(next.weightKg) - 85) < 0.01)
    }

    @Test func timedOffAndBodyweightExercisesKeepTheirWeights() throws {
        let env = try makeEnv()
        let plank = RoutineExercise(exerciseId: "0464", sets: 3, reps: 1, sec: 30, mode: .time)
        let fixedCurl = RoutineExercise(exerciseId: "0586", sets: 3, reps: 12, weightKg: UnitConverter.toKg(100, from: .lb),
                                        policy: .off)
        let dip = RoutineExercise(exerciseId: "0251", sets: 3, reps: 10)
        let core = Routine(name: "Core", paused: true, exercises: [plank, fixedCurl, dip])
        try env.routines.upsert(core)
        let result = try #require(try env.resumeAtReturnWeights(core.id))
        #expect(result.lowered == 0)
        let saved = try #require(try env.routines.routine(core.id))
        #expect(!saved.paused)
        #expect(saved.exercises == core.exercises)
    }

    @Test func onlyAPausedRoutineCanBeResumed() throws {
        let env = try makeEnv()
        #expect(try env.resumeAtReturnWeights(UUID()) == nil)
        let push = try #require(try env.routines.all().first { !$0.paused })
        #expect(try env.resumeAtReturnWeights(push.id) == nil)
        let legs = try legsRoutine(env)
        #expect(try env.resumeAtReturnWeights(legs.id) != nil)
        #expect(try env.resumeAtReturnWeights(legs.id) == nil)
    }

    private func logFinished(_ env: AppEnvironment, _ id: String, sets: Int, reps: Int, lb weight: Double, daysAgo: Int) throws {
        let start = env.now().addingTimeInterval(Double(-daysAgo) * 86_400)
        try env.workouts.save(Workout(startedAt: start, endedAt: start.addingTimeInterval(3_000), name: "Past", entries: [
            WorkoutEntry(exerciseId: id, sets: (0..<sets).map { _ in
                WorkoutSet(weightKg: UnitConverter.toKg(weight, from: .lb), reps: reps, done: true, completedAt: start) }),
        ]))
    }

    @Test func aWeightAtTheFloorIsLeftToProgression() throws {
        let env = try makeEnv()
        try logFinished(env, "0085", sets: 3, reps: 8, lb: 45, daysAgo: 1)
        let before = try #require(try legsRoutine(env).exercises.first { $0.exerciseId == "0085" })
        let result = try #require(try env.resumeAtReturnWeights(try legsRoutine(env).id))
        #expect(result.lowered == 5)
        let after = try #require(try legsRoutine(env).exercises.first { $0.exerciseId == "0085" })
        #expect(after.weightKg == before.weightKg)
        #expect(abs(lb(after.weightKg) - 135) < 0.01)
    }

    @Test func afterHeavierHistoryTheFirstSessionBackIsPlannedAtSixtyPercent() throws {
        let env = try makeEnv()
        try logFinished(env, "0043", sets: 4, reps: 6, lb: 135, daysAgo: 7)
        _ = try env.resumeAtReturnWeights(try legsRoutine(env).id)
        let legs = try legsRoutine(env)
        let squat = try #require(legs.exercises.first { $0.exerciseId == "0043" })
        let first = SessionPlanner.suggestion(for: squat, policy: squat.policy ?? legs.policy, profile: env.profile,
                                              exercise: env.library.exercise("0043"),
                                              history: try env.workouts.history(exerciseId: "0043", limit: 5))
        #expect(abs(lb(first.weightKg) - 80) < 0.01)
        #expect(first.reason == .planned)
    }
}
