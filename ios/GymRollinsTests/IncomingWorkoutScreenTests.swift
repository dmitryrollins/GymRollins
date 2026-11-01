import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@Suite struct IncomingWorkoutScreenTests {
    private let library = ExerciseLibrary(exercises: [
        Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
        Exercise(id: "0251", name: "chest dip", bodyPart: "chest", equipment: "body weight", target: "pectorals"),
    ])
    private let day = "2026-11-01"
    private let benchLink = URL(string: "gymrollins://w#1.0025_3_8-10")!

    private func screen(_ url: URL, running: Bool = false, current: TodayPlan? = nil,
                        history: @escaping (String) -> [SessionResult] = { _ in [] }) -> IncomingWorkoutScreen {
        IncomingWorkoutScreen.make(url: url, link: WorkoutLink(host: nil), library: library, profile: Profile(), day: day,
                                   isWorkoutRunning: running, currentPlan: current, history: history, gym: nil)
    }

    private func preview(_ url: URL, current: TodayPlan? = nil,
                         history: @escaping (String) -> [SessionResult] = { _ in [] }) throws -> IncomingWorkoutScreen.Preview {
        guard case let .preview(preview) = screen(url, current: current, history: history) else {
            throw Failure.notAPreview
        }
        return preview
    }

    private enum Failure: Error { case notAPreview }

    private func kg(_ pounds: Double) -> Double { UnitConverter.toKg(pounds, from: .lb) }

    /// Spec criterion 1: the same link, two people, each with their own weight.
    @Test func eachPersonSeesTheirOwnWeight() throws {
        let heavy = try preview(benchLink) { _ in [SessionResult(date: .now, weightKg: kg(140), reps: [8, 8, 8])] }
        let light = try preview(benchLink) { _ in [SessionResult(date: .now, weightKg: kg(95), reps: [8, 8, 8])] }
        #expect(heavy.rows[0].row.subtitle.contains("140 lb"))
        #expect(light.rows[0].row.subtitle.contains("95 lb"))
        #expect(!light.rows[0].row.subtitle.contains("140"))
    }

    /// Spec criterion 2.
    @Test func aNewExerciseSaysSetOnFirstSet() throws {
        let shown = try preview(benchLink)
        #expect(shown.rows[0].note == "Set on first set")
    }

    @Test func aKnownExerciseHasNoNote() throws {
        let shown = try preview(benchLink) { _ in [SessionResult(date: .now, weightKg: kg(95), reps: [8, 8, 8])] }
        #expect(shown.rows[0].note == nil)
    }

    @Test func bodyweightHasNoNote() throws {
        let shown = try preview(URL(string: "gymrollins://w#1.0251_3_10")!)
        #expect(shown.rows[0].note == nil)
    }

    @Test func thePlanCarriesNoWeightAndPinsItsItems() throws {
        let plan = try preview(benchLink).plan
        #expect(plan.exercises.map(\.weightKg) == [nil])
        #expect(plan.gymPinned == Set(plan.exercises.map(\.id)))
        #expect(plan.day == day)
    }

    @Test func countsTheExercises() throws {
        #expect(try preview(benchLink).countText == "1 exercise")
        #expect(try preview(URL(string: "gymrollins://w#1.0025_3_10.0251_3_10")!).countText == "2 exercises")
    }

    @Test func saysHowManyWereDropped() throws {
        #expect(try preview(benchLink).droppedNotice == nil)
        #expect(try preview(URL(string: "gymrollins://w#1.0025_3_10.ZZZZ_3_10")!).droppedNotice
            == "1 exercise isn't in your version of the app.")
        #expect(try preview(URL(string: "gymrollins://w#1.0025_3_10.ZZZZ_3_10.YYYY_3_10")!).droppedNotice
            == "2 exercises aren't in your version of the app.")
    }

    @Test(arguments: ["gymrollins://w#nonsense", "gymrollins://w#1.0025_99_10", "gymrollins://w#1.ZZZZ_3_10",
                      "https://evil.example/w#1.0025_3_10", "gymrollins://x#1.0025_3_10", "gymrollins://w"])
    func damagedLinksSayDamaged(text: String) throws {
        #expect(screen(try #require(URL(string: text))) == .damaged)
    }

    @Test func aNewerLinkAsksForAnUpdate() {
        #expect(screen(URL(string: "gymrollins://w#2.anything")!) == .tooNew)
    }

    /// Spec criterion 7.
    @Test func aRunningWorkoutChangesNothing() {
        #expect(screen(benchLink, running: true) == .workoutRunning)
    }

    @Test func aDamagedLinkDuringAWorkoutStillSaysDamaged() {
        #expect(screen(URL(string: "gymrollins://w#nonsense")!, running: true) == .damaged)
    }

    // MARK: "This replaces today's plan"

    private let routine = Routine(name: "Push", exercises: [RoutineExercise(exerciseId: "0025", sets: 3, reps: 10)])

    @Test func aPlainScheduledPlanNeedsNoWarning() throws {
        let plan = TodayPlan.make(scheduled: routine, routines: [routine], lastDone: [:], day: day)
        #expect(try !preview(benchLink, current: plan).replacesToday)
    }

    @Test func noPlanNeedsNoWarning() throws {
        #expect(try !preview(benchLink).replacesToday)
    }

    @Test func aBuiltPlanIsWarnedAbout() throws {
        let plan = TodayPlan.built(name: "Built", items: routine.exercises, day: day)
        #expect(try preview(benchLink, current: plan).replacesToday)
    }

    @Test func anEditedPlanIsWarnedAbout() throws {
        let plan = TodayPlan.make(scheduled: routine, routines: [routine], lastDone: [:], day: day)
            .adding([RoutineExercise(exerciseId: "0251", sets: 3, reps: 10)])
        #expect(try preview(benchLink, current: plan).replacesToday)
    }

    @Test func aSwitchedPlanIsWarnedAbout() throws {
        let plan = TodayPlan.make(scheduled: nil, routines: [routine], lastDone: [:], day: day).switched(to: routine)
        #expect(try preview(benchLink, current: plan).replacesToday)
    }
}

/// `useSharedWorkout` on a real environment: today's plan, the next day and a running workout.
@MainActor
@Suite struct UseSharedWorkoutTests {
    private func environment() throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: "UseSharedWorkoutTests.\(UUID())"))
        return try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]),
                                  defaults: defaults)
    }

    private func plan(_ env: AppEnvironment) -> TodayPlan {
        TodayPlan.shared(items: [RoutineExercise(exerciseId: "0025", sets: 3, reps: 10)], day: TodayPlan.dayKey(env.now()))
    }

    @Test func becomesTodaysPlan() throws {
        let env = try environment()
        #expect(env.useSharedWorkout(plan(env)))
        #expect(try env.todaysPlan().plan.title == "Shared workout")
    }

    /// Spec criterion 4.
    @Test func theNormalPlanIsBackTheNextDayAndRoutinesDontChange() throws {
        let env = try environment()
        let before = try env.routines.all()
        #expect(env.useSharedWorkout(plan(env)))
        let tomorrow = env.now().addingTimeInterval(24 * 60 * 60)
        #expect(try env.todaysPlan(at: tomorrow).plan.title != "Shared workout")
        #expect(try env.routines.all() == before)
    }

    /// The sheet was open when a workout started on the watch.
    @Test func refusedWhileAWorkoutRuns() throws {
        let env = try environment()
        env.startSession(routine: nil)
        let before = try env.todaysPlan().plan
        #expect(!env.useSharedWorkout(plan(env)))
        #expect(try env.todaysPlan().plan == before)
    }
}
