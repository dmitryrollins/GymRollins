import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// A finished workout at a gym adds what it shows the gym has (owner, 2026-11-18): the list fills in from training. A
/// choice of kinds adds its first kind and dumbbells and kettlebells get the weights used (owner, 2026-11-22).
@MainActor
@Suite struct GymEquipmentRecordingTests {
    /// Dumbbell-only 0294 (10 kg) and cable-only 1269 done, kettlebell 0541 done, dumbbells-and-a-bench 1285 (12 kg)
    /// done, barbell 1370 left with no set done.
    private func workout(at gymId: UUID?, start: TimeInterval = 1_793_000_000) -> Workout {
        func entry(_ id: String, kg: Double = 10, done: Bool = true) -> WorkoutEntry {
            WorkoutEntry(exerciseId: id, sets: [WorkoutSet(weightKg: kg, reps: 10, done: done)])
        }
        let start = Date(timeIntervalSince1970: start)
        return Workout(startedAt: start, endedAt: start.addingTimeInterval(3_000), name: "Workout",
                       entries: [entry("0294"), entry("1269"), entry("0541"), entry("1285", kg: 12),
                                 entry("1370", done: false)],
                       gymId: gymId)
    }

    private func listing(_ rig: GymTestRig, _ gym: Gym, _ kind: String) throws -> GymListing {
        try #require(try rig.env.gyms.listings(gymId: gym.id).first { $0.item.kindId == kind })
    }

    @Test func aWorkoutAtAGymAddsWhatItShows() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage", ["kettlebells": .fixed(kg: [20, 24])])

        let learned = rig.env.recordGymEquipment(from: workout(at: gym.id))

        #expect(learned == LearnedEquipment(gymName: "Garage", kinds: [
            .init(name: "Dumbbells", weightsKg: [10, 12]), .init(name: "Cable station", weightsKg: []),
            .init(name: "Flat bench", weightsKg: []),
        ]))
        let listings = try rig.env.gyms.listings(gymId: gym.id)
        #expect(listings.map(\.item.kindId).sorted() == ["cable-station", "dumbbells", "flat-bench", "kettlebells"])
        let added = listings.filter { $0.item.kindId != "kettlebells" }
        #expect(added.allSatisfy { $0.visibility == .device && $0.photoFile == nil && $0.item.isGeneric })
        #expect(try listing(rig, gym, "cable-station").loads == ListingLoads.none)
        #expect(try listing(rig, gym, "flat-bench").loads == ListingLoads.none)
    }

    @Test func dumbbellsGetTheWeightsUsedAndAreMarked() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage")

        rig.env.recordGymEquipment(from: workout(at: gym.id))

        let dumbbells = try listing(rig, gym, "dumbbells")
        #expect(dumbbells.loads == .fixed(kg: [10, 12]) && dumbbells.loadsFromWorkouts)
    }

    /// A kettlebell list the user made is theirs: the 10 kg set in the workout doesn't join it.
    @Test func aListTheUserMadeIsNeverChanged() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage", ["kettlebells": .fixed(kg: [20, 24])])

        rig.env.recordGymEquipment(from: workout(at: gym.id))

        let kettlebells = try listing(rig, gym, "kettlebells")
        #expect(kettlebells.loads == .fixed(kg: [20, 24]) && !kettlebells.loadsFromWorkouts)
    }

    @Test func aLaterWorkoutAddsItsNewWeightsToALearnedList() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage")
        rig.env.recordGymEquipment(from: workout(at: gym.id))
        let later = Workout(startedAt: Date(timeIntervalSince1970: 1_793_100_000), endedAt: nil, name: "Later",
                            entries: [WorkoutEntry(exerciseId: "0294", sets: [
                                WorkoutSet(weightKg: 14, reps: 8, done: true), WorkoutSet(weightKg: 10, reps: 8, done: true),
                            ])], gymId: gym.id)

        #expect(rig.env.recordGymEquipment(from: later) == nil, "nothing new to show on the card")

        #expect(try listing(rig, gym, "dumbbells").loads == .fixed(kg: [10, 12, 14]))
    }

    /// Older builds learned dumbbells and kettlebells with no weights.
    @Test func aBareListingFromAnOlderBuildIsFilled() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage", ["dumbbells": ListingLoads.none])

        #expect(rig.env.recordGymEquipment(from: workout(at: gym.id))?.kinds.map(\.name)
            == ["Cable station", "Kettlebells", "Flat bench"])

        let dumbbells = try listing(rig, gym, "dumbbells")
        #expect(dumbbells.loads == .fixed(kg: [10, 12]) && dumbbells.loadsFromWorkouts)
    }

    /// The learned weights are only the ones seen so far: a heavier suggestion isn't cut down to them.
    @Test func learnedWeightsAreNotFittedTo() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage")
        rig.env.setCurrentGym(gym.id)
        rig.env.recordGymEquipment(from: workout(at: gym.id))

        #expect(rig.env.gymLoads("0294") == ListingLoads.none)

        let dumbbells = try listing(rig, gym, "dumbbells")
        try rig.env.gyms.updateListing(dumbbells.id, loads: .fixed(kg: [10, 12]), quantity: 1, notes: nil)
        #expect(rig.env.gymLoads("0294") == .fixed(kg: [10, 12]), "the user's own list fits like any fixed set")
    }

    @Test func theSummaryCardNamesTheWeightsInTheUsersUnit() {
        let learned = LearnedEquipment(gymName: "Garage", kinds: [
            .init(name: "Dumbbells", weightsKg: [11.34, 13.61]), .init(name: "Cable station", weightsKg: []),
        ])
        #expect(learned.label(unit: .lb) == "Dumbbells (25 \u{00B7} 30 lb), Cable station")
        #expect(learned.label(unit: .kg) == "Dumbbells (11 \u{00B7} 14 kg), Cable station")
    }

    @Test func theSameWorkoutAgainAddsNothing() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage")
        rig.env.recordGymEquipment(from: workout(at: gym.id))

        #expect(rig.env.recordGymEquipment(from: workout(at: gym.id)) == nil)
        #expect(try rig.env.gyms.listings(gymId: gym.id).count == 4)
    }

    /// A workout that uses it shows it's there, even after the owner deleted it.
    @Test func aDeletedItemComesBackWhenAWorkoutUsesItAgain() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage")
        rig.env.recordGymEquipment(from: workout(at: gym.id))
        let dumbbells = try #require(try rig.env.gyms.listings(gymId: gym.id).first { $0.item.kindId == "dumbbells" })
        try rig.env.removeListing(dumbbells.id)

        let learned = rig.env.recordGymEquipment(from: workout(at: gym.id))

        #expect(learned?.kinds.map(\.name) == ["Dumbbells"])
        #expect(try listing(rig, gym, "dumbbells").loads == .fixed(kg: [10, 12]), "and with its weights again")
    }

    @Test func aWorkoutWithNoGymOrAGoneGymAddsNothing() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage")
        #expect(rig.env.recordGymEquipment(from: workout(at: nil)) == nil)
        try rig.env.deleteGym(gym.id)
        #expect(rig.env.recordGymEquipment(from: workout(at: gym.id)) == nil)
        #expect(try rig.env.gyms.gyms().isEmpty)
    }

    /// Today's rows read the gym again: the weight for 0294 now comes from the learned dumbbells (the learned weights aren't fitted to).
    @Test func whatWasAddedReachesTheRules() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage")
        rig.env.setCurrentGym(gym.id)
        #expect(rig.env.gymMatcher()?.loadListingId(for: "0294") == nil)

        rig.env.recordGymEquipment(from: workout(at: gym.id))

        #expect(rig.env.gymMatcher()?.loadListingId(for: "0294") != nil)
    }
}
