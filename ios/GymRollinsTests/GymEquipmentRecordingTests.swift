import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// A finished workout at a gym adds what it shows the gym has (owner, 2026-11-18): the list fills in from training.
@MainActor
@Suite struct GymEquipmentRecordingTests {
    /// Dumbbell-only 0294 and cable-only 1269 done, kettlebell 0541 done, dumbbells-and-a-bench 1285 done, barbell
    /// 1370 left with no set done.
    private func workout(at gymId: UUID?) -> Workout {
        func entry(_ id: String, done: Bool = true) -> WorkoutEntry {
            WorkoutEntry(exerciseId: id, sets: [WorkoutSet(weightKg: 10, reps: 10, done: done)])
        }
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        return Workout(startedAt: start, endedAt: start.addingTimeInterval(3_000), name: "Workout",
                       entries: [entry("0294"), entry("1269"), entry("0541"), entry("1285"), entry("1370", done: false)],
                       gymId: gymId)
    }

    @Test func aWorkoutAtAGymAddsWhatItShows() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage", ["kettlebells": .fixed(kg: [20, 24])])

        let learned = rig.env.recordGymEquipment(from: workout(at: gym.id))

        #expect(learned == LearnedEquipment(gymName: "Garage", kindNames: ["Dumbbells", "Cable station"]))
        let listings = try rig.env.gyms.listings(gymId: gym.id)
        #expect(listings.map(\.item.kindId).sorted() == ["cable-station", "dumbbells", "kettlebells"])
        let added = listings.filter { $0.item.kindId != "kettlebells" }
        #expect(added.allSatisfy { $0.visibility == .device && $0.photoFile == nil && $0.item.isGeneric })
        #expect(added.allSatisfy { $0.loads == ListingLoads.none })
    }

    @Test func theSameWorkoutAgainAddsNothing() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage")
        rig.env.recordGymEquipment(from: workout(at: gym.id))

        #expect(rig.env.recordGymEquipment(from: workout(at: gym.id)) == nil)
        #expect(try rig.env.gyms.listings(gymId: gym.id).count == 3)
    }

    /// A workout that uses it shows it's there, even after the owner deleted it.
    @Test func aDeletedItemComesBackWhenAWorkoutUsesItAgain() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage")
        rig.env.recordGymEquipment(from: workout(at: gym.id))
        let dumbbells = try #require(try rig.env.gyms.listings(gymId: gym.id).first { $0.item.kindId == "dumbbells" })
        try rig.env.removeListing(dumbbells.id)

        let learned = rig.env.recordGymEquipment(from: workout(at: gym.id))

        #expect(learned?.kindNames == ["Dumbbells"])
    }

    @Test func aWorkoutWithNoGymOrAGoneGymAddsNothing() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage")
        #expect(rig.env.recordGymEquipment(from: workout(at: nil)) == nil)
        try rig.env.deleteGym(gym.id)
        #expect(rig.env.recordGymEquipment(from: workout(at: gym.id)) == nil)
        #expect(try rig.env.gyms.gyms().isEmpty)
    }

    /// Today's rows read the gym again: the weight for 0294 now comes from the learned dumbbells (loads not known yet).
    @Test func whatWasAddedReachesTheRules() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage")
        rig.env.setCurrentGym(gym.id)
        #expect(rig.env.gymMatcher()?.loadListingId(for: "0294") == nil)

        rig.env.recordGymEquipment(from: workout(at: gym.id))

        #expect(rig.env.gymMatcher()?.loadListingId(for: "0294") != nil)
    }
}
