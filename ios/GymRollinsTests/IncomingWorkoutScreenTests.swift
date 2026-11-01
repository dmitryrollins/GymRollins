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

    private func screen(_ url: URL, running: Bool = false, current: TodayPlan? = nil, routines: [Routine] = [],
                        profile: Profile = Profile(), gym: TodayGymContext? = nil,
                        history: @escaping (String) -> [SessionResult] = { _ in [] }) -> IncomingWorkoutScreen {
        IncomingWorkoutScreen.make(url: url, link: WorkoutLink(host: nil), library: library, profile: profile, day: day,
                                   isWorkoutRunning: running, currentPlan: current, routines: routines, history: history,
                                   gym: gym)
    }

    private func preview(_ url: URL, current: TodayPlan? = nil, routines: [Routine] = [], profile: Profile = Profile(),
                         history: @escaping (String) -> [SessionResult] = { _ in [] }) throws -> IncomingWorkoutScreen.Preview {
        guard case let .preview(preview) = screen(url, current: current, routines: routines, profile: profile,
                                                  history: history) else {
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

    // MARK: A person's weight comes from their own numbers

    private func session(_ pounds: Double, reps: [Int], at date: Date = Date(timeIntervalSince1970: 1_000_000)) -> SessionResult {
        SessionResult(date: date, weightKg: kg(pounds), reps: reps)
    }

    @Test func aSendersLongerSetsDoNotDeloadAPartnerWhoDidEight() throws {
        let twelves = URL(string: "gymrollins://w#1.0025_3_12")!
        let misses = [session(95, reps: [8, 8, 8]), session(95, reps: [8, 8, 8])]
        let shown = try preview(twelves) { _ in misses }
        #expect(shown.rows[0].row.subtitle.contains("95 lb"))
        #expect(shown.plan.exercises[0].fixedWeightKg == kg(95))
    }

    @Test func bodyweightWithHistoryAtZeroStaysZero() throws {
        let dips = URL(string: "gymrollins://w#1.0251_3_10")!
        let shown = try preview(dips) { _ in [session(0, reps: [10, 10, 10])] }
        #expect((shown.rows[0].row.suggestedKg ?? 0) == 0)
        #expect(!shown.rows[0].row.subtitle.contains("lb"))
        #expect(shown.rows[0].note == nil)
    }

    @Test func aRoutineCutAfterTheLastSessionWins() throws {
        let cut = Routine(name: "Rehab", exercises: [
            RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, weightKg: 60,
                            weightSetAt: Date(timeIntervalSince1970: 2_000_000)),
        ])
        let history = [SessionResult(date: Date(timeIntervalSince1970: 1_000_000), weightKg: 100, reps: [10, 10, 10])]
        let shown = try preview(benchLink, routines: [cut]) { _ in history }
        let fixed = try #require(shown.plan.exercises[0].fixedWeightKg)
        #expect(abs(fixed - 60) < 2.5)
    }

    @Test func aRoutineWeightWithNoHistoryShowsThatWeight() throws {
        let routine = Routine(name: "Push", exercises: [RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, weightKg: kg(135))])
        let shown = try preview(benchLink, routines: [routine])
        #expect(shown.rows[0].row.subtitle.contains("135 lb"))
        #expect(shown.rows[0].note == nil)
    }

    @Test func aRoutineWithoutAWeightAndNoHistoryStillSaysSetOnFirstSet() throws {
        let shown = try preview(benchLink, routines: [routine])
        #expect(shown.rows[0].note == "Set on first set")
    }

    @Test func severalRoutineItemsTakeTheLatestWeightSetAt() throws {
        let older = Routine(name: "A", exercises: [RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, weightKg: kg(100),
                                                                   weightSetAt: Date(timeIntervalSince1970: 100))])
        let newer = Routine(name: "B", exercises: [RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, weightKg: kg(80),
                                                                   weightSetAt: Date(timeIntervalSince1970: 200))])
        let shown = try preview(benchLink, routines: [older, newer])
        #expect(shown.rows[0].row.subtitle.contains("80 lb"))
    }

    /// What the sheet shows is what starting the plan starts with, first working set by first working set.
    private func firstWorkingWeights(_ shown: IncomingWorkoutScreen.Preview, profile: Profile,
                                     history: @escaping (String) -> [SessionResult],
                                     gym: TodayGymContext?) throws -> [Double] {
        let workout = SessionPlanner.start(routine: try #require(shown.plan.routineToStart), profile: profile,
                                           library: library, now: .now, history: history,
                                           loads: { gym?.loads(for: $0) })
        return workout.entries.map { $0.sets.first { !$0.warmup }?.weightKg ?? -1 }
    }

    @Test func theSheetShowsWhatStartingUses() throws {
        let link = URL(string: "gymrollins://w#1.0025_3_12.0251_3_10")!
        let people: [[String: [SessionResult]]] = [
            [:],
            ["0025": [session(95, reps: [8, 8, 8]), session(95, reps: [8, 8, 8])], "0251": [session(0, reps: [10, 10, 10])]],
            ["0025": [session(200, reps: [12, 12, 12])]],
        ]
        for person in people {
            let history: (String) -> [SessionResult] = { person[$0] ?? [] }
            let shown = try preview(link, history: history)
            let started = try firstWorkingWeights(shown, profile: Profile(), history: history, gym: nil)
            #expect(shown.rows.map { $0.row.suggestedKg ?? 0 } == started)
        }
    }

    @Test func theSheetShowsWhatStartingUsesAtAGym() throws {
        let link = URL(string: "gymrollins://w#1.0025_3_12")!
        let history: (String) -> [SessionResult] = { _ in [self.session(97, reps: [8, 8, 8])] }
        let kind = EquipmentKind(id: "bell", name: "bell", category: .freeWeight, load: .fixedSet)
        let listing = InventoryListing(id: UUID(), kindId: "bell", loads: .fixed(kg: [40, 50, 60]))
        let matcher = InventoryMatcher(requirements: ExerciseRequirements(groups: ["0025": [["bell"]]]), kinds: [kind],
                                       inventory: GymInventory(gymName: "Gym", listings: [listing]))
        let gym = TodayGymContext(matcher: matcher, photo: { _ in nil })
        guard case let .preview(shown) = screen(link, gym: gym, history: history) else { throw Failure.notAPreview }
        let started = try firstWorkingWeights(shown, profile: Profile(), history: history, gym: gym)
        #expect(shown.rows.map { $0.row.suggestedKg ?? 0 } == started)
        #expect([40.0, 50, 60].contains(started[0]))
    }

    @Test func oddPlatesNeverStartANegativeWeight() throws {
        let odd = Profile(plateInventory: PlateInventory(unit: .lb, bar: 45, plates: [5, 10, 25, 45]))
        #expect(odd.barbellRounder.step == 10 && odd.barbellRounder.offset == 5)
        let shown = try preview(benchLink, profile: odd)
        let started = try firstWorkingWeights(shown, profile: odd, history: { _ in [] }, gym: nil)
        #expect(started == [0])
        #expect((shown.rows[0].row.suggestedKg ?? 0) == 0)
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
