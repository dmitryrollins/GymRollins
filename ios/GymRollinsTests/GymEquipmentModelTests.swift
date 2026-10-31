import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@MainActor
@Suite struct GymEquipmentModelTests {
    private func model(_ rig: GymTestRig, _ gym: Gym, unit: WeightUnit = .lb,
                       coverage: [GymEquipmentModel.Coverage] = []) throws -> GymEquipmentModel {
        GymEquipmentModel(gym: try #require(try rig.env.gyms.gym(gym.id)), listings: try rig.env.gyms.listings(gymId: gym.id),
                          catalog: rig.env.gymCatalog, unit: unit, coverage: coverage)
    }

    private func matcher(_ rig: GymTestRig, _ gym: Gym) throws -> InventoryMatcher {
        try #require(rig.env.gymMatcher(gymId: gym.id))
    }

    @Test func groupsByCategoryInOrder() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("All", ["treadmill": .none, "resistance-bands": .none, "power-rack": .none,
                                      "flat-bench": .none, "dumbbells": .fixed(kg: [10]),
                                      "lat-pulldown": .stack(maxKg: 80, stepKg: nil),
                                      "leg-press": .plates])
        let titles = try model(rig, gym).sections.map(\.title)
        #expect(titles == ["Machines", "Cables", "Free weights", "Benches", "Racks", "Cardio", "Accessories"])
        let machines = try #require(try model(rig, gym).sections.first)
        #expect(machines.tiles.map(\.title) == ["Leg press"])
    }

    @Test func emptyCategoriesAreLeftOut() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("KB", kettlebellGym)
        #expect(try model(rig, gym).sections.map(\.title) == ["Free weights", "Benches"])
        #expect(try model(rig, try rig.gym("Empty")).sections.isEmpty)
        #expect(try model(rig, try rig.gym("Empty 2")).isEmpty)
    }

    @Test func coverageIsAmberBelowThree() {
        #expect(GymEquipmentModel.Coverage(muscle: .legs, count: 2).isThin)
        #expect(GymEquipmentModel.Coverage(muscle: .legs, count: 0).isThin)
        #expect(!GymEquipmentModel.Coverage(muscle: .chest, count: 3).isThin)
        #expect(GymEquipmentModel.Coverage(muscle: .chest, count: 6).text == "Chest 6")
    }

    @Test func coverageCountsOnlyServingListings() throws {
        let rig = try GymTestRig.make()
        let date = rig.env.now()
        let exercises = rig.env.library.exercises
        let cardio = try rig.gym("Cardio", ["treadmill": .none, "stationary-bike": .none])
        let none = GymEquipmentModel.coverage(matcher: try matcher(rig, cardio), exercises: exercises, asOf: date)
        #expect(none.map(\.muscle) == BuildMuscle.allCases)
        #expect(none.allSatisfy { $0.count == 0 }, "cardio machines serve no strength exercise")
        let rich = try rig.gym("Rich", richGym)
        let counts = GymEquipmentModel.coverage(matcher: try matcher(rig, rich), exercises: exercises, asOf: date)
        #expect(counts.first { $0.muscle == .chest }?.count ?? 0 >= 3)
        let withTreadmill = try rig.gym("Rich+", richGym.merging(["treadmill": .none]) { a, _ in a })
        #expect(GymEquipmentModel.coverage(matcher: try matcher(rig, withTreadmill), exercises: exercises, asOf: date)
                    .map(\.count) == counts.map(\.count), "a treadmill adds nothing")
    }

    @Test func coverageOnTheRealLibraryIsMeasured() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Full", Dictionary(uniqueKeysWithValues: rig.env.gymCatalog.kinds.map { ($0.id, ListingLoads.none) }))
        let matcher = try matcher(rig, gym)
        let exercises = rig.env.library.exercises
        let date = rig.env.now()
        var counts: [GymEquipmentModel.Coverage] = []
        let elapsed = ContinuousClock().measure {
            counts = GymEquipmentModel.coverage(matcher: matcher, exercises: exercises, asOf: date)
        }
        print("COVERAGE-TIMING exercises=\(exercises.count) listings=\(rig.env.gymCatalog.kinds.count) elapsed=\(elapsed)")
        #expect(counts.count == 6)
        #expect(elapsed < .seconds(1), "\(elapsed)")
    }

    @Test func headerCountsAndAddress() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.env.gyms.addPrivateGym(name: "Garage", address: "Home")
        for kind in ["dumbbells", "flat-bench", "power-rack"] {
            try rig.env.gyms.addListing(NewListing(gymId: gym.id, kindId: kind))
        }
        let full = try model(rig, gym)
        #expect(full.subtitle == "Home \u{00B7} 3 items")
        #expect(full.itemCount == 3)
        let one = try rig.gym("One", ["flat-bench": .none])
        #expect(try model(rig, one).subtitle == "1 item")
    }

    @Test func tilesCarryNameBrandLoadsAndQuantity() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Tiles")
        try rig.env.gyms.addListing(NewListing(gymId: gym.id, kindId: "lat-pulldown", brand: "Hammer", model: "Iso",
                                               loads: .stack(maxKg: 113.4, stepKg: nil), quantity: 2))
        let tile = try #require(try model(rig, gym).sections.first?.tiles.first)
        #expect(tile.title == "Lat pulldown")
        #expect(tile.brandAndModel == "Hammer Iso")
        #expect(tile.loadsText == "to 250 lb")
        #expect(tile.quantityText == "\u{00D7}2")
        let single = try rig.gym("Single", ["flat-bench": .none])
        #expect(try model(rig, single).sections.first?.tiles.first?.quantityText == nil)
    }

    @Test func unknownKindShowsUpdateTheApp() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Future", ["flat-bench": .none, "hologram-press": .plates])
        let model = try model(rig, gym)
        let other = try #require(model.sections.last)
        #expect(other.title == "Other")
        let tile = try #require(other.tiles.first)
        #expect(tile.title == "Update the app to use this item")
        #expect(!tile.isKnown)
        #expect(tile.loadsText == nil)
        #expect(model.itemCount == 2)
        let known = try rig.gym("Known", ["flat-bench": .none])
        let date = rig.env.now(), exercises = rig.env.library.exercises
        #expect(GymEquipmentModel.coverage(matcher: try matcher(rig, gym), exercises: exercises, asOf: date)
                    == GymEquipmentModel.coverage(matcher: try matcher(rig, known), exercises: exercises, asOf: date),
                "the rules ignore the unknown kind")
    }

    @Test func badgeForEachState() throws {
        #expect(GymEquipmentModel.ListingBadge.onlyMe.text == "Only me")
        #expect(GymEquipmentModel.ListingBadge.confirmed(7).text == "\u{2713} 7")
        #expect(GymEquipmentModel.ListingBadge.underReview.text == "Under review")
        #expect(GymEquipmentModel.ListingBadge.onlyMe.kind == .neutral)
        #expect(GymEquipmentModel.ListingBadge.confirmed(1).kind == .success)
        #expect(GymEquipmentModel.ListingBadge.underReview.kind == .record)
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Badges", ["flat-bench": .none])
        let listing = try #require(try rig.env.gyms.listings(gymId: gym.id).first)
        #expect(GymEquipmentModel.ListingBadge(listing) == .onlyMe)
        #expect(try model(rig, gym).sections.first?.tiles.first?.badge == .onlyMe)
    }
}
