import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Plan 39, decision 5: an outside workout counts as a workout day for the streak and the weekly goal when both hold:
/// - it lasts 10 minutes or more;
/// - it isn't part of a GymRollins workout.
///
/// Turning "Workouts from other apps" off takes it out again.
@MainActor
@Suite struct ActivityStreakTests {
    private let iso = ISO8601DateFormatter()

    private func makeEnv() throws -> AppEnvironment {
        try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fakeHealth", "-fixedNow",
                                                             "2026-09-26T09:00:00Z"]))
    }

    private func date(_ text: String) throws -> Date { try #require(iso.date(from: text)) }

    private func outside(_ start: Date, minutes: Double, kind: String = "walking") -> HealthActivity {
        HealthActivity(id: UUID(), kind: kind, startedAt: start, endedAt: start.addingTimeInterval(minutes * 60),
                       durationS: minutes * 60, sourceName: "Apple Watch", fromWatch: true)
    }

    @Test func aWalkOnAnotherDayCountsButNotOneDuringAWorkoutOrUnderTenMinutes() throws {
        let env = try makeEnv()
        let monday = try date("2026-09-21T17:00:00Z")
        try env.workouts.save(Workout(startedAt: monday, endedAt: monday.addingTimeInterval(3_600), name: "Push"))
        let before = env.insights().streak.thisWeekDays
        try env.activities.add(outside(try date("2026-09-23T07:00:00Z"), minutes: 45), editedAt: env.now())
        try env.activities.add(outside(monday.addingTimeInterval(300), minutes: 50, kind: "traditional_strength"),
                               editedAt: env.now())
        try env.activities.add(outside(try date("2026-09-24T07:00:00Z"), minutes: 5, kind: "cooldown"),
                               editedAt: env.now())
        #expect(env.insights().streak.thisWeekDays == before + 1)
    }

    @Test func turningWorkoutsFromOtherAppsOffStopsThemCounting() throws {
        let env = try makeEnv()
        try env.activities.add(outside(try date("2026-09-23T07:00:00Z"), minutes: 45), editedAt: env.now())
        let counted = env.insights().streak.thisWeekDays
        env.setReadsOutsideWorkouts(false)
        #expect(env.insights().streak.thisWeekDays == counted - 1)
    }

    @Test func aWalkCanBeTheDayThatCompletesTheWeek() throws {
        let env = try makeEnv()
        let goal = env.profile.trainingDays
        try #require((2...6).contains(goal), "the seeded profile trains 2 to 6 days")
        let days = try (21...26).map { try date("2026-09-\($0)T12:00:00Z") } // Mon 21 … Sat 26, midday UTC
        for day in days.prefix(goal - 2) {
            try env.workouts.save(Workout(startedAt: day, endedAt: day.addingTimeInterval(3_600), name: "Push"))
        }
        let finished = Workout(startedAt: days[5], endedAt: days[5].addingTimeInterval(1_800), name: "Pull")
        try env.workouts.save(finished)
        #expect(try !env.completesWeeklyGoal(finished), "a workout day short")

        try env.activities.add(outside(days[goal - 2].addingTimeInterval(7_200), minutes: 40), editedAt: env.now())
        #expect(try env.completesWeeklyGoal(finished))
    }
}
