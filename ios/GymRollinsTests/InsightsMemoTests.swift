import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// The insights and the resolved outside workouts are computed once and reused (Today's streak chip and recovery card,
/// Log and Body all ask) until the data they come from may have changed: a data revision, the reading switch, a
/// workout or outside workout added or deleted, the plan, the goal, the limits note, or a new minute.
@MainActor
@Suite struct InsightsMemoTests {
    private let iso = ISO8601DateFormatter()

    private func makeEnv() throws -> AppEnvironment {
        try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fakeHealth", "-fixedNow",
                                                             "2026-09-26T09:00:00Z"]))
    }

    private func date(_ text: String) throws -> Date { try #require(iso.date(from: text)) }

    private func workout(id: UUID, at start: Date) -> Workout {
        Workout(id: id, startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "Push")
    }

    private func outside(_ start: Date, minutes: Double) -> HealthActivity {
        HealthActivity(id: UUID(), kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(minutes * 60),
                       durationS: minutes * 60, sourceName: "Apple Watch", fromWatch: true)
    }

    /// A workout moved into this week (same count of workouts) shows once the data revision says the data changed.
    @Test func anEditShowsAfterTheDataRevisionBumps() throws {
        let env = try makeEnv()
        let id = UUID()
        try env.workouts.save(workout(id: id, at: try date("2026-09-14T17:00:00Z"))) // the week before
        env.bumpDataRevision()
        let before = env.insights().streak.thisWeekDays
        try env.workouts.save(workout(id: id, at: try date("2026-09-22T17:00:00Z"))) // this week
        #expect(env.insights().streak.thisWeekDays == before, "reused until the data revision bumps")
        env.bumpDataRevision()
        #expect(env.insights().streak.thisWeekDays == before + 1)
    }

    /// An outside workout or a workout added (or deleted) shows at once, even before a data revision.
    @Test func addedRowsShowAtOnce() throws {
        let env = try makeEnv()
        let before = env.insights().streak.thisWeekDays
        try env.activities.add(outside(try date("2026-09-23T07:00:00Z"), minutes: 45), editedAt: env.now())
        #expect(env.resolvedActivities().counted.count == 1)
        #expect(env.insights().streak.thisWeekDays == before + 1)
        try env.workouts.save(workout(id: UUID(), at: try date("2026-09-24T17:00:00Z")))
        #expect(env.insights().streak.thisWeekDays == before + 2)
    }

    @Test func resolvedActivitiesFollowAnEditAfterTheBumpAndTheSwitch() throws {
        let env = try makeEnv()
        let walk = outside(try date("2026-09-23T07:00:00Z"), minutes: 45)
        try env.activities.add(walk, editedAt: env.now())
        #expect(env.resolvedActivities().shown.map(\.id) == [walk.id])
        // A GymRollins workout moved onto the walk (same count of workouts) takes it once the data changed.
        let id = UUID()
        try env.workouts.save(workout(id: id, at: try date("2026-09-20T07:00:00Z")))
        #expect(env.resolvedActivities().shown.map(\.id) == [walk.id])
        try env.workouts.save(workout(id: id, at: walk.startedAt))
        env.bumpDataRevision()
        #expect(env.resolvedActivities().shown.isEmpty)
        #expect(env.resolvedActivities().attachedTo[walk.id] == id)
        env.setReadsOutsideWorkouts(false)
        #expect(env.resolvedActivities() == .none)
    }

    /// The weekly goal and the limits note are part of what the snapshot was made from.
    @Test func theGoalChangesTheSnapshot() throws {
        let env = try makeEnv()
        let goal = env.insights().streak.goal
        try env.profiles.save(Profile(trainingDays: goal == 3 ? 4 : 3))
        env.reloadProfile()
        #expect(env.insights().streak.goal == (goal == 3 ? 4 : 3))
        #expect(env.insights().limited.isEmpty)
        try env.profiles.save(Profile(trainingDays: env.profile.trainingDays, limits: "Knee: no squats",
                                      limitsUntil: env.now().addingTimeInterval(7 * 86_400)))
        env.reloadProfile()
        let expected = LimitedMuscles.from(limits: env.profile.limits)
        #expect(!expected.isEmpty)
        #expect(env.insights().limited == expected)
    }
}
