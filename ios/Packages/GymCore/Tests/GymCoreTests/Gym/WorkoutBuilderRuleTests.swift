import Foundation
import Testing
@testable import GymCore

/// Rules that would otherwise break without any test failing.
@Suite struct WorkoutBuilderRuleTests {
    private let day = 20_400
    private let cables = ["c-cable-fly", "c-cable-crossover", "c-cable-press"]
    private var cableGym: GymInventory {
        GymInventory(gymName: "Cables", listings: [InventoryListing(id: GymFixtures.id(50), kindId: "cable-station",
                                                                    loads: .stack(maxKg: 90, stepKg: 4.5))])
    }

    private func builder(_ inventory: GymInventory, history: [Workout] = [], loggedCounts: [String: Int] = [:],
                         preferences: [String: ExercisePreference] = [:]) -> WorkoutBuilder {
        WorkoutBuilder(matcher: GymFixtures.matcher(inventory), exercises: GymFixtures.exercises, history: history,
                       loggedCounts: loggedCounts, preferences: preferences)
    }

    private func request(_ length: BuildLength) -> BuildRequest {
        BuildRequest(muscles: [.chest], length: length, date: GymFixtures.date(day: day))
    }

    private func ids(_ built: BuiltWorkout) -> [String] { built.items.map(\.exercise.exerciseId) }

    @Test func aRepeatCannotPassTheMachineCap() {
        let built = builder(cableGym, history: [GymFixtures.workout(day: day - 1, cables)],
                            preferences: ["c-pushup": .never]).build(request(.medium))
        #expect(ids(built).filter(cables.contains).count == 2, "\(ids(built))")
    }

    @Test func barsAreFreeWeightsAndTheSmithIsAMachine() {
        #expect(GymFixtures.kinds.first { $0.id == "barbell" }?.isMachine == false)
        #expect(EquipmentKind(id: "smith-machine", name: "Smith", category: .rack, load: .plateLoaded).isMachine)
    }

    @Test func aCompoundFillStillComesAfterAnIsolationMachineExercise() {
        let deck = InventoryListing(id: GymFixtures.id(50), kindId: "pec-deck")
        let gym = GymInventory(gymName: "Deck", listings: [deck])
        #expect(ids(builder(gym).build(request(.short))) == ["c-pec-deck", "c-pushup"])
    }

    @Test func theSameUtcDayGivesTheSameWorkoutAtAnyHour() {
        for offset in 0..<30 {
            let start = Double(day + offset) * 86_400
            func build(_ time: Double) -> [String] {
                ids(builder(GymFixtures.iron).build(BuildRequest(muscles: [.chest], length: .long,
                                                                 date: Date(timeIntervalSince1970: start + time))))
            }
            #expect(build(60) == build(86_340))
        }
    }

    @Test(arguments: ["c-cable-fly", "c-cable-crossover", "c-cable-press"])
    func theMoreLoggedExerciseRanksFirst(id: String) {
        let built = builder(cableGym, loggedCounts: [id: 5]).build(request(.short))
        #expect(ids(built).contains(id), "\(ids(built))")
    }

    @Test(arguments: ["c-cable-fly", "c-cable-crossover", "c-cable-press"])
    func aLessExerciseRanksLast(id: String) {
        let built = builder(cableGym, preferences: [id: .less]).build(request(.short))
        #expect(!ids(built).contains(id), "\(ids(built))")
    }
}
