import Foundation
import Testing
@testable import GymCore

/// What the builder does when fresh equipment exercises run out, and the inputs that must not change its result.
@Suite struct WorkoutBuilderFallbackTests {
    private let day = 20_400
    private let allChest = ["c-bb-bench", "c-db-press", "c-db-incline", "c-machine-press", "c-pec-deck", "c-cable-fly",
                            "c-cable-crossover", "c-cable-press"]

    private func build(_ inventory: GymInventory, _ muscles: [BuildMuscle], _ length: BuildLength,
                       history: [Workout] = [], avoid: [String] = [],
                       preferences: [String: ExercisePreference] = [:]) -> BuiltWorkout {
        WorkoutBuilder(matcher: GymFixtures.matcher(inventory), exercises: GymFixtures.exercises, history: history,
                       preferences: preferences)
            .build(BuildRequest(muscles: muscles, length: length, date: GymFixtures.date(day: day), avoid: avoid))
    }

    private func ids(_ built: BuiltWorkout) -> [String] { built.items.map(\.exercise.exerciseId) }

    private func station(_ n: Int, _ kindId: String, confirmed: Int = 0, isOwn: Bool = false) -> InventoryListing {
        InventoryListing(id: GymFixtures.id(n), kindId: kindId, loads: .stack(maxKg: 90, stepKg: 4.5),
                         confirmCount: confirmed, isOwn: isOwn)
    }

    // MARK: Fallback order

    @Test func aFreshNoEquipmentExerciseComesBeforeARepeat() throws {
        let built = build(GymFixtures.iron, [.chest], .short, history: [GymFixtures.workout(day: day - 1, allChest)])
        let pushup = try #require(built.items.first { $0.exercise.exerciseId == "c-pushup" })
        #expect(pushup.isBodyweightFill)
        #expect(pushup.repeatOf == nil)
        #expect(built.items.count == 3)
        #expect(built.items.filter { $0.repeatOf != nil }.count == 2)
    }

    @Test func aRepeatedNoEquipmentExerciseKeepsItsBadge() throws {
        let cables = GymInventory(gymName: "Cables", listings: [station(50, "cable-station")])
        let history = [GymFixtures.workout(day: day - 1, ["c-cable-fly", "c-cable-crossover", "c-pushup"])]
        let built = build(cables, [.chest], .medium, history: history)
        let pushup = try #require(built.items.first { $0.exercise.exerciseId == "c-pushup" })
        #expect(pushup.isBodyweightFill)
        #expect(pushup.repeatOf == GymFixtures.workout(day: day - 1, []).startedAt)
    }

    @Test func rebuildRepeatsAnExerciseBeforeShowingTheSameOne() {
        let recent = ["c-machine-press", "c-pec-deck", "c-cable-fly", "c-cable-crossover", "c-cable-press"]
        let history = [GymFixtures.workout(day: day - 1, recent)]
        let first = build(GymFixtures.iron, [.chest], .short, history: history)
        let shown = ids(first)
        #expect(Set(shown) == ["c-bb-bench", "c-db-press", "c-db-incline"])
        let rebuilt = build(GymFixtures.iron, [.chest], .short, history: history, avoid: shown)
        #expect(Set(ids(rebuilt)).isDisjoint(with: shown), "\(ids(rebuilt))")
        #expect(rebuilt.items.count == 3)
    }

    @Test func avoidedAndRecentIsTheLastResortAndStillARepeat() {
        let history = [GymFixtures.workout(day: day - 1, ["b-kb-row"])]
        let built = build(GymFixtures.home, [.back], .short, history: history, avoid: ["b-kb-row"])
        #expect(ids(built) == ["b-kb-row"])
        #expect(built.items.first?.repeatOf == GymFixtures.workout(day: day - 1, []).startedAt)
    }

    @Test func onceEverythingIsAvoidedTheOldestShownComesBack() {
        let built = build(GymFixtures.home, [.arms], .short, avoid: ["a-kb-skull", "a-kb-curl"])
        #expect(built.items.count == 2)
        let shownFirst = build(GymFixtures.home, [.arms, .back, .chest], .short, avoid: ["a-kb-skull", "a-kb-curl"])
        #expect(shownFirst.items.first { $0.muscle == .arms }?.exercise.exerciseId == "a-kb-skull")
        let shownAgain = build(GymFixtures.home, [.arms, .back, .chest], .short,
                               avoid: ["a-kb-skull", "a-kb-curl", "a-kb-skull"])
        #expect(shownAgain.items.first { $0.muscle == .arms }?.exercise.exerciseId == "a-kb-curl")
    }

    @Test func neverAppliesToNoEquipmentExercises() {
        let cables = GymInventory(gymName: "Cables", listings: [station(50, "cable-station")])
        let built = build(cables, [.chest], .medium, preferences: ["c-pushup": .never])
        #expect(!ids(built).contains("c-pushup"))
    }

    // MARK: The machine cap moves on to other listings

    @Test func aCappedListingFallsBackToAnotherOfItsKind() {
        let gym = GymInventory(gymName: "Two stacks", listings: [station(50, "cable-station", confirmed: 9),
                                                                 station(51, "cable-station", confirmed: 1)])
        let built = build(gym, [.chest], .long)
        let cables = built.items.filter { $0.exercise.exerciseId.hasPrefix("c-cable") }
        #expect(cables.map(\.match.loadListingId) == [GymFixtures.id(50), GymFixtures.id(50), GymFixtures.id(51)])
        #expect(built.thin == [ThinInventoryNotice(muscle: .chest, itemCount: 2)])
    }

    @Test func aCappedStationFallsBackToTheOtherKindInTheGroup() throws {
        let gym = GymInventory(gymName: "Cables", listings: [station(50, "cable-station", confirmed: 9),
                                                             station(51, "lat-pulldown", confirmed: 3)])
        let built = build(gym, [.chest, .arms, .back], .long)
        let pulldown = try #require(built.items.first { $0.exercise.exerciseId == "b-pulldown" })
        #expect(pulldown.match.loadListingId == GymFixtures.id(51))
    }

    // MARK: Ranking

    @Test func anOwnListingDoesNotDemoteItsKind() {
        let shared = InventoryListing(id: GymFixtures.id(50), kindId: "dumbbells", confirmCount: 9)
        let cable = station(51, "cable-station", confirmed: 5)
        let own = InventoryListing(id: GymFixtures.id(52), kindId: "dumbbells", isOwn: true)
        let gym = GymInventory(gymName: "G", listings: [shared, cable, own])
        let builder = WorkoutBuilder(matcher: GymFixtures.matcher(gym), exercises: GymFixtures.exercises, history: [])
        let ranked = builder.pool(for: .arms, day: day, asOf: GymFixtures.date(day: day)).equipment
        #expect(ranked.first?.exercise.id == "a-db-curl", "\(ranked.map(\.exercise.id))")
        #expect(ranked.first?.match.loadListingId == own.id, "the link still goes to the user's own listing")
    }

    @Test func anOwnListingOfASiblingKindDoesNotDemoteTheExercise() {
        let cable = station(50, "cable-station", confirmed: 9)
        let dumbbells = InventoryListing(id: GymFixtures.id(51), kindId: "dumbbells", confirmCount: 5)
        let bench = InventoryListing(id: GymFixtures.id(53), kindId: "flat-bench")
        let own = station(52, "lat-pulldown", isOwn: true)
        let gym = GymInventory(gymName: "G", listings: [cable, dumbbells, bench, own])
        let builder = WorkoutBuilder(matcher: GymFixtures.matcher(gym), exercises: GymFixtures.exercises, history: [])
        let ranked = builder.pool(for: .back, day: day, asOf: GymFixtures.date(day: day)).equipment
        #expect(ranked.first?.exercise.id == "b-pulldown", "\(ranked.map(\.exercise.id))")
        #expect(ranked.first?.match.loadListingId == own.id)
    }

    // MARK: Chips and slots

    @Test func chipsThatDontFitTheLengthAreReported() {
        #expect(build(GymFixtures.iron, BuildMuscle.allCases, .short).skipped == [.arms, .legs, .core])
        #expect(build(GymFixtures.iron, BuildMuscle.allCases, .medium).skipped == [.core])
        #expect(build(GymFixtures.iron, BuildMuscle.allCases, .long).skipped.isEmpty)
        #expect(build(GymFixtures.iron, [.chest, .back, .arms], .short).skipped.isEmpty)
    }

    // MARK: What counts as recent

    @Test func setsThatWerentDoneDontMakeAnExerciseRecent() {
        let start = GymFixtures.date(day: day - 1)
        let warmUpOnly = WorkoutEntry(exerciseId: "c-bb-bench",
                                      sets: [WorkoutSet(weightKg: 20, reps: 5, done: true, warmup: true)])
        let notDone = WorkoutEntry(exerciseId: "c-db-press", sets: [WorkoutSet(weightKg: 20, reps: 5)])
        let history = [Workout(startedAt: start, name: "Empty", entries: [warmUpOnly, notDone])]
        #expect(ids(build(GymFixtures.iron, [.chest], .short, history: history))
            == ids(build(GymFixtures.iron, [.chest], .short)))
    }

    @Test func workoutsAfterTheRequestDontCount() {
        let future = (1...3).map {
            GymFixtures.workout(day: day + $0, ["c-machine-press", "c-pec-deck", "c-cable-fly"])
        }
        let yesterday = GymFixtures.workout(day: day - 1, ["c-bb-bench"])
        let built = build(GymFixtures.iron, [.chest], .short, history: future + [yesterday])
        #expect(!ids(built).contains("c-bb-bench"), "yesterday's bench is still recent")
        #expect(ids(built).contains("c-machine-press") || ids(built).contains("c-pec-deck")
            || ids(built).contains("c-db-press"))
    }

    @Test func workoutsAtTheSameTimeDontDependOnTheirOrder() {
        let start = GymFixtures.date(day: day - 1)
        let history = allChest.enumerated().map { index, exerciseId in
            Workout(id: GymFixtures.id(200 + index), startedAt: start, name: "Tied", entries: [
                WorkoutEntry(exerciseId: exerciseId, sets: [WorkoutSet(weightKg: 20, reps: 8, done: true)]),
            ])
        }
        #expect(ids(build(GymFixtures.iron, [.chest], .short, history: history))
            == ids(build(GymFixtures.iron, [.chest], .short, history: history.reversed())))
    }

    // MARK: Item count

    @Test func itemCountMatchesTheThinNotice() throws {
        let gym = GymInventory(gymName: "Cables", listings: [station(50, "cable-station"), station(51, "cable-station")])
        let builder = WorkoutBuilder(matcher: GymFixtures.matcher(gym), exercises: GymFixtures.exercises, history: [])
        let date = GymFixtures.date(day: day)
        let built = builder.build(BuildRequest(muscles: [.chest], length: .long, date: date))
        let notice = try #require(built.thin.first)
        #expect(builder.itemCount(for: .chest, asOf: date) == notice.itemCount)
        #expect(builder.itemCount(for: .chest, asOf: date) == 2, "each listing counts once, however many exercises use it")
        #expect(builder.itemCount(for: .legs, asOf: date) == 0)
    }
}
