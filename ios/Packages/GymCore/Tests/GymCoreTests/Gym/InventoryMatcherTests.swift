import Foundation
import Testing
@testable import GymCore

@Suite struct InventoryMatcherTests {
    private let home = GymFixtures.matcher(GymFixtures.home)
    private let iron = GymFixtures.matcher(GymFixtures.iron)

    @Test func availableExerciseUsesOneListingPerGroupAndNamesTheLoadListing() {
        #expect(home.availability(of: "a-kb-skull") == .available(InventoryMatch(
            listingIds: [GymFixtures.id(1), GymFixtures.id(2)], loadListingId: GymFixtures.id(1))))
    }

    @Test func oneListingCanCoverSeveralGroups() {
        // The bench press station is both the bench and the rack.
        #expect(iron.availability(of: "c-bb-bench") == .available(InventoryMatch(
            listingIds: [GymFixtures.id(10), GymFixtures.id(11)], loadListingId: GymFixtures.id(10))))
    }

    @Test func missingReportsTheFirstUncoveredGroup() {
        #expect(home.availability(of: "c-bb-bench") == .missing(["barbell"]))
        #expect(home.availability(of: "c-db-incline") == .missing(["dumbbells"]))
        #expect(iron.availability(of: "b-pullup") == .available(InventoryMatch(
            listingIds: [GymFixtures.id(12)], loadListingId: nil)), "a power rack has a pull-up bar")
    }

    @Test func noEquipmentAndUnmapped() {
        #expect(home.availability(of: "c-pushup") == .available(.noEquipment))
        #expect(home.needsNoEquipment("c-pushup"))
        #expect(!home.needsNoEquipment("b-kb-row"))
        #expect(home.availability(of: "x-shrug") == .unmapped)
        #expect(home.availability(of: "no-such-exercise") == .unmapped)
    }

    @Test func prefersOwnListingsThenMoreConfirmations() {
        let shared = InventoryListing(id: GymFixtures.id(30), kindId: "dumbbells", confirmCount: 12)
        let mine = InventoryListing(id: GymFixtures.id(31), kindId: "dumbbells", confirmCount: 0, isOwn: true)
        let weaker = InventoryListing(id: GymFixtures.id(32), kindId: "dumbbells", confirmCount: 2)
        let both = GymFixtures.matcher(GymInventory(gymName: "G", listings: [weaker, shared, mine]))
        #expect(both.availability(of: "a-db-curl")
            == .available(InventoryMatch(listingIds: [mine.id], loadListingId: mine.id)))
        let sharedOnly = GymFixtures.matcher(GymInventory(gymName: "G", listings: [weaker, shared]))
        #expect(sharedOnly.availability(of: "a-db-curl")
            == .available(InventoryMatch(listingIds: [shared.id], loadListingId: shared.id)))
    }

    @Test func listingsOfUnknownKindsAreIgnored() {
        let future = InventoryListing(id: GymFixtures.id(40), kindId: "hover-bench", confirmCount: 99)
        let matcher = GymFixtures.matcher(GymInventory(gymName: "G", listings: [future]))
        #expect(matcher.listing(future.id) == nil)
        #expect(matcher.availability(of: "c-db-press") == .missing(["dumbbells"]))
    }
}
