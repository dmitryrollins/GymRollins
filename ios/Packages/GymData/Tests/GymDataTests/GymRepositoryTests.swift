import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

@MainActor
@Suite struct GymRepositoryTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    private var repo: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }

    private func makeGym(_ name: String = "Iron") throws -> Gym { try repo.addPrivateGym(name: name, address: nil) }

    @discardableResult
    private func add(_ gym: Gym, kind: String = "cable-stack", brand: String? = nil, model: String? = nil,
                     loads: ListingLoads = .none, quantity: Int = 1, photo: String? = nil) throws -> GymListing {
        f.clock.advance()
        return try repo.addListing(NewListing(gymId: gym.id, kindId: kind, brand: brand, model: model, loads: loads,
                                              quantity: quantity, photoFile: photo))
    }

    private func expectInvalid(_ body: () throws -> Void) {
        #expect(throws: GymDataError.self) { try body() }
    }

    @Test func addPrivateGymTrimsAndValidates() throws {
        defer { f.tearDown() }
        expectInvalid { _ = try repo.addPrivateGym(name: "  ", address: nil) }
        expectInvalid { _ = try repo.addPrivateGym(name: String(repeating: "a", count: 121), address: nil) }
        expectInvalid { _ = try repo.addPrivateGym(name: "Ok", address: String(repeating: "a", count: 301)) }
        let gym = try repo.addPrivateGym(name: "  Home  ", address: "   ")
        #expect(gym.name == "Home")
        #expect(gym.address == nil)
        #expect(gym.visibility == .device)
        #expect(gym.mapsPlaceId == nil)
        #expect(gym.isPrivate)
        let withAddress = try repo.addPrivateGym(name: "B", address: " 1 Main St ")
        #expect(withAddress.address == "1 Main St")
        #expect(try repo.addPrivateGym(name: String(repeating: "a", count: 120), address: nil).name.count == 120)
    }

    @Test func addMapsGymRefusesImpossibleCoordinates() throws {
        defer { f.tearDown() }
        for (latitude, longitude) in [(91.0, 0.0), (-91.0, 0.0), (0.0, 181.0), (0.0, -181.0), (.nan, 0.0), (0.0, .infinity)] {
            #expect(throws: GymDataError.self) {
                try repo.addMapsGym(placeId: "P", name: "Gym", address: nil, latitude: latitude, longitude: longitude)
            }
        }
        #expect(try repo.gyms().isEmpty)
    }

    @Test func addListingRefusesAnEmptyKind() throws {
        defer { f.tearDown() }
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        #expect(throws: GymDataError.self) { try repo.addListing(NewListing(gymId: gym.id, kindId: " ")) }
    }

    @Test func addMapsGymIsIdempotentPerPlace() throws {
        defer { f.tearDown() }
        let a = try repo.addMapsGym(placeId: "P1", name: "Planet", address: "x", latitude: 1, longitude: 2)
        let b = try repo.addMapsGym(placeId: "P1", name: "Other", address: nil, latitude: 3, longitude: 4)
        #expect(a.id == b.id)
        #expect(b.name == "Planet")
        #expect(try repo.gyms().count == 1)
        #expect(a.mapsPlaceId == "P1")
        #expect(a.latitude == 1 && a.longitude == 2)
        #expect(!a.isPrivate)
        _ = try repo.addMapsGym(placeId: "P2", name: "Second", address: nil, latitude: 0, longitude: 0)
        #expect(try repo.gyms().count == 2)
    }

    @Test func gymsAreSortedByName() throws {
        defer { f.tearDown() }
        for name in ["Charlie", "alpha", "Bravo"] { _ = try makeGym(name) }
        #expect(try repo.gyms().map(\.name) == ["alpha", "Bravo", "Charlie"])
    }

    @Test func updateGymChangesPrivateGymsOnly() throws {
        defer { f.tearDown() }
        let gym = try makeGym("Old")
        let updated = try repo.updateGym(gym.id, name: " New ", address: "Addr")
        #expect(updated.name == "New" && updated.address == "Addr")
        let maps = try repo.addMapsGym(placeId: "P", name: "M", address: nil, latitude: 0, longitude: 0)
        expectInvalid { _ = try repo.updateGym(maps.id, name: "Z", address: nil) }
        expectInvalid { _ = try repo.updateGym(gym.id, name: "", address: nil) }
        expectInvalid { _ = try repo.updateGym(UUID(), name: "Z", address: nil) }
    }

    @Test func addListingStoresEverythingOnThePhone() throws {
        defer { f.tearDown() }
        let gym = try makeGym()
        let listing = try add(gym, loads: .plates, quantity: 2, photo: "a.jpg")
        #expect(listing.visibility == .device)
        #expect(listing.uploadState == .local)
        #expect(listing.isOwn)
        #expect(listing.status == .active)
        #expect(listing.confirmCount == 0)
        #expect(listing.remoteId == nil)
        #expect(listing.uploadError == nil)
        #expect(listing.gymId == gym.id)
        #expect(listing.quantity == 2)
        #expect(listing.photoFile == "a.jpg")
        #expect(listing.loads == .plates)
        #expect(try repo.listing(listing.id) == listing)
    }

    @Test func addListingValidates() throws {
        defer { f.tearDown() }
        let gym = try makeGym()
        func bad(_ listing: NewListing) { expectInvalid { _ = try repo.addListing(listing) } }
        func new(brand: String? = nil, model: String? = nil, loads: ListingLoads = .none, quantity: Int = 1,
                 notes: String? = nil, gymId: UUID? = nil) -> NewListing {
            NewListing(gymId: gymId ?? gym.id, kindId: "cable-stack", brand: brand, model: model, loads: loads,
                       quantity: quantity, notes: notes)
        }
        bad(new(quantity: 0))
        bad(new(quantity: 51))
        bad(new(notes: String(repeating: "n", count: 281)))
        bad(new(brand: String(repeating: "b", count: 61)))
        bad(new(model: String(repeating: "m", count: 81)))
        bad(new(loads: .stack(maxKg: 0, stepKg: nil)))
        bad(new(loads: .stack(maxKg: -5, stepKg: nil)))
        bad(new(loads: .stack(maxKg: 1001, stepKg: nil)))
        bad(new(loads: .stack(maxKg: 100, stepKg: 101)))
        bad(new(loads: .stack(maxKg: 100, stepKg: 0)))
        bad(new(loads: .stack(maxKg: 100, stepKg: -1)))
        bad(new(loads: .fixed(kg: [])))
        bad(new(loads: .fixed(kg: Array(repeating: 10, count: 61))))
        bad(new(loads: .fixed(kg: [10, 0])))
        bad(new(loads: .fixed(kg: [501])))
        bad(new(gymId: UUID()))
        _ = try repo.addListing(new(brand: String(repeating: "b", count: 60), model: String(repeating: "m", count: 80),
                                    loads: .stack(maxKg: 1000, stepKg: 50), quantity: 50,
                                    notes: String(repeating: "n", count: 280)))
        _ = try repo.addListing(new(loads: .fixed(kg: Array(repeating: 500, count: 60))))
        #expect(try repo.listings(gymId: gym.id).count == 2)
    }

    @Test func loadsBelowWhatTheServerAcceptsAreRefusedLocally() throws {
        defer { f.tearDown() }
        let gym = try makeGym()
        func bad(_ loads: ListingLoads) {
            expectInvalid { _ = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", loads: loads)) }
        }
        bad(.stack(maxKg: 0.1, stepKg: nil))
        bad(.stack(maxKg: 100, stepKg: 0.1))
        bad(.stack(maxKg: 100, stepKg: 51))
        bad(.fixed(kg: [0.1]))
        bad(.fixed(kg: [10, 0.2]))
        _ = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", loads: .stack(maxKg: 0.25, stepKg: 0.25)))
        _ = try repo.addListing(NewListing(gymId: gym.id, kindId: "kettlebell", loads: .fixed(kg: [0.25])))
        let listing = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", loads: .plates))
        expectInvalid { _ = try repo.updateListing(listing.id, loads: .stack(maxKg: 0.1, stepKg: nil), quantity: 1, notes: nil) }
    }

    @Test func genericItemIsStablePerKind() throws {
        defer { f.tearDown() }
        let gym = try makeGym()
        let a = try add(gym, kind: "leg-press")
        let b = try add(gym, kind: "leg-press")
        #expect(a.item.id == b.item.id)
        #expect(a.item.brand == nil && a.item.model == nil && a.item.isGeneric)
        #expect(try f.context.fetchCount(FetchDescriptor<EquipmentItemRecord>()) == 1)
        let c = try add(gym, kind: "cable-stack")
        #expect(c.item.id != a.item.id)
        let other = try makeGym("Other")
        #expect(try add(other, kind: "leg-press").item.id == a.item.id)
    }

    @Test func genericItemIdMatchesTheServerSeed() throws {
        defer { f.tearDown() }
        let listing = try add(try makeGym(), kind: "dumbbells")
        #expect(listing.item.id == UUID(uuidString: "cdd9d434-9eca-5d33-8406-2bdea6b4c561"))
    }

    @Test func sameBrandAndModelReuseTheItem() throws {
        defer { f.tearDown() }
        let gym = try makeGym()
        let a = try add(gym, brand: "Hammer", model: "Strength MTS")
        let b = try add(gym, brand: " hammer ", model: "strength mts")
        #expect(a.item.id == b.item.id)
        #expect(try f.context.fetchCount(FetchDescriptor<EquipmentItemRecord>()) == 1)
        let c = try add(gym, brand: "Hammer", model: "Other")
        #expect(c.item.id != a.item.id)
        let d = try add(gym, kind: "leg-press", brand: "Hammer", model: "Strength MTS")
        #expect(d.item.id != a.item.id)
        #expect(!a.item.isGeneric)
    }

    @Test func catalogueItemsCountGyms() throws {
        defer { f.tearDown() }
        let one = try makeGym("One"), two = try makeGym("Two")
        try add(one, brand: "Hammer", model: "A")
        try add(two, brand: "Hammer", model: "A")
        try add(two, brand: "Hammer", model: "A")
        try add(one, brand: "Life", model: "B")
        try add(one)
        try add(one, kind: "leg-press", brand: "Hammer", model: "C")
        let items = try repo.catalogueItems(kindId: "cable-stack")
        #expect(items.count == 2)
        let a = try #require(items.first { $0.item.model == "A" })
        #expect(a.gymCount == 2)
        #expect(items.first { $0.item.model == "B" }?.gymCount == 1)
        #expect(items.allSatisfy { !$0.item.isGeneric })
        #expect(items.first?.item.model == "A")
    }

    @Test func listingsOnlyReturnActiveOnesInOrder() throws {
        defer { f.tearDown() }
        let gym = try makeGym()
        let first = try add(gym, kind: "k1")
        let flagged = try add(gym, kind: "k2")
        let removed = try add(gym, kind: "k3")
        let last = try add(gym, kind: "k4")
        for (id, status) in [(flagged.id, ListingStatus.flagged), (removed.id, .removed)] {
            let record = try #require(try f.context.fetch(FetchDescriptor<GymListingRecord>(
                predicate: #Predicate { $0.id == id })).first)
            record.statusRaw = status.rawValue
        }
        try f.context.save()
        #expect(try repo.listings(gymId: gym.id).map(\.id) == [first.id, last.id])
    }

    @Test func inventoryMapsActiveListings() throws {
        defer { f.tearDown() }
        let gym = try makeGym("Iron")
        let a = try add(gym, kind: "cable-stack", loads: .stack(maxKg: 90, stepKg: 5))
        let b = try add(gym, kind: "kettlebell", loads: .fixed(kg: [16, 24]))
        let aId = a.id
        let record = try #require(try f.context.fetch(FetchDescriptor<GymListingRecord>(
            predicate: #Predicate { $0.id == aId })).first)
        record.confirmCount = 3
        record.isOwn = false
        try f.context.save()
        let inventory = try repo.inventory(gymId: gym.id)
        #expect(inventory.gymName == "Iron")
        #expect(inventory.listings == [
            InventoryListing(id: a.id, kindId: "cable-stack", loads: .stack(maxKg: 90, stepKg: 5), confirmCount: 3,
                             isOwn: false),
            InventoryListing(id: b.id, kindId: "kettlebell", loads: .fixed(kg: [16, 24]), confirmCount: 0, isOwn: true),
        ])
        expectInvalid { _ = try repo.inventory(gymId: UUID()) }
    }

    @Test func updateListingChangesLoadsQuantityAndNote() throws {
        defer { f.tearDown() }
        let gym = try makeGym()
        let listing = try add(gym)
        f.clock.advance()
        let updated = try repo.updateListing(listing.id, loads: .stack(maxKg: 80, stepKg: nil), quantity: 3, notes: " left ")
        #expect(updated.loads == .stack(maxKg: 80, stepKg: nil))
        #expect(updated.quantity == 3)
        #expect(updated.notes == "left")
        #expect(try repo.listing(listing.id) == updated)
        expectInvalid { _ = try repo.updateListing(listing.id, loads: .none, quantity: 0, notes: nil) }
        expectInvalid { _ = try repo.updateListing(UUID(), loads: .none, quantity: 1, notes: nil) }
    }

    @Test func removeListingReturnsItsPhoto() throws {
        defer { f.tearDown() }
        let gym = try makeGym()
        let withPhoto = try add(gym, photo: "p.jpg")
        let without = try add(gym, kind: "leg-press")
        #expect(try repo.removeListing(withPhoto.id) == "p.jpg")
        #expect(try repo.removeListing(without.id) == nil)
        #expect(try repo.listings(gymId: gym.id).isEmpty)
        expectInvalid { _ = try repo.removeListing(without.id) }
    }

    @Test func setPhotoAttachesAndReturnsThePreviousFile() throws {
        defer { f.tearDown() }
        let gym = try makeGym()
        let bare = try add(gym)
        #expect(try repo.setPhoto(bare.id, file: "a.jpg") == nil)
        #expect(try repo.listing(bare.id)?.photoFile == "a.jpg")
        #expect(try repo.setPhoto(bare.id, file: "b.jpg") == "a.jpg")
        #expect(try repo.listing(bare.id)?.photoFile == "b.jpg")
        #expect(try repo.listings(gymId: gym.id).first?.photoFile == "b.jpg")
        expectInvalid { _ = try repo.setPhoto(UUID(), file: "c.jpg") }
        expectInvalid { _ = try repo.setPhoto(bare.id, file: "  ") }
    }

    @Test func deleteGymRemovesItsListingsAndReturnsTheirPhotos() throws {
        defer { f.tearDown() }
        let gone = try makeGym("Gone"), kept = try makeGym("Kept")
        let shared = try add(gone, brand: "Hammer", model: "A", photo: "1.jpg")
        try add(gone, kind: "leg-press", photo: "2.jpg")
        try add(gone, kind: "k")
        try add(kept, brand: "Hammer", model: "A")
        #expect(try repo.deleteGym(gone.id).sorted() == ["1.jpg", "2.jpg"])
        #expect(try repo.gyms().map(\.id) == [kept.id])
        #expect(try repo.listings(gymId: gone.id).isEmpty)
        #expect(try repo.listings(gymId: kept.id).first?.item.id == shared.item.id)
        #expect(try repo.catalogueItems(kindId: "cable-stack").first?.gymCount == 1)
        #expect(try repo.deleteGym(UUID()).isEmpty)
    }

    @Test func itemCountsPerGym() throws {
        defer { f.tearDown() }
        let one = try makeGym("One"), two = try makeGym("Two"), empty = try makeGym("Empty")
        try add(one); try add(one, kind: "leg-press"); try add(two)
        let counts = try repo.itemCounts()
        #expect(counts[one.id] == 2)
        #expect(counts[two.id] == 1)
        #expect(counts[empty.id] == nil || counts[empty.id] == 0)
    }

    @Test func unreadableLoadsReadAsNone() throws {
        defer { f.tearDown() }
        let gym = try makeGym()
        let listing = try add(gym, loads: .plates)
        let record = try #require(try f.context.fetch(FetchDescriptor<GymListingRecord>()).first)
        record.loadsData = Data("{\"type\":\"hologram\"}".utf8)
        try f.context.save()
        #expect(try repo.listing(listing.id)?.loads == ListingLoads.none)
    }
}
