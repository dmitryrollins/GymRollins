import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// After account deletion detaches the user's photos on the server, the phone must not keep naming objects that are
/// gone, or it never uploads those pictures again.
@MainActor
@Suite struct SyncStoreForgetPhotosTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    private var repo: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }

    /// A synced listing the server already has, with a picture on the phone and on the server.
    private func uploaded(file: String? = "a.jpg", path: String? = "old.jpg") throws -> GymListing {
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        let listing = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", photoFile: file))
        try repo.makeSynced(listing: listing.id)
        for row in try f.store.dirtyGymListings() {
            try f.store.markSynced(.gymListings, id: row.value.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                                   serverUpdatedAt: f.clock.now)
        }
        for row in try f.store.dirtyGyms() {
            try f.store.markSynced(.gyms, id: row.value.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                                   serverUpdatedAt: f.clock.now)
        }
        try f.store.setRemotePhotoPath(listingId: listing.id, path: path)
        return listing
    }

    private func record(_ id: UUID) throws -> GymListingRecord {
        try #require(try f.context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first)
    }

    @Test func aSyncedListingWithAPictureOnThePhoneForgetsTheServerName() throws {
        defer { f.tearDown() }
        let listing = try uploaded()
        try f.store.forgetRemotePhotos()
        let row = try record(listing.id)
        #expect(row.remotePhotoPath == nil)
        #expect(row.photoFile == "a.jpg")
        #expect(row.dirty)
        let pushed = try f.store.dirtyGymListings().first { $0.value.id == listing.id }
        #expect(pushed?.value.photoFile == "a.jpg" && pushed?.value.remotePhotoPath == nil,
                "the next sync uploads it again")
    }

    @Test func rowsWithNothingToReuploadAreLeftAlone() throws {
        defer { f.tearDown() }
        let noFile = try uploaded(file: nil, path: "other.jpg") // the picture is only on the server
        let noPath = try uploaded(file: "b.jpg", path: nil)
        let plainPhone = try repo.addPrivateGym(name: "Phone", address: nil)
        let device = try repo.addListing(NewListing(gymId: plainPhone.id, kindId: "cable-stack", photoFile: "c.jpg"))
        try f.store.forgetRemotePhotos()
        #expect(try record(noFile.id).remotePhotoPath == "other.jpg")
        #expect(try record(noFile.id).dirty == false)
        #expect(try record(noPath.id).dirty == false)
        #expect(try record(device.id).dirty == false)
    }

    @Test func aPullAfterTheDetachKeepsThePictureFileAndTheEdit() throws {
        defer { f.tearDown() }
        let listing = try uploaded()
        try f.store.forgetRemotePhotos()
        // The server's row now holds no path (detach cleared it), and its edit time is the old one.
        let at = f.clock.now
        let value = SyncedListing(id: listing.id, gymId: listing.gymId, kindId: "cable-stack", brand: nil, model: nil,
                                  loads: .stack(maxKg: 90, stepKg: 5), quantity: 1, notes: nil, photoFile: nil,
                                  remotePhotoPath: nil)
        let files = try f.store.applyRemote(gymListings: [SyncRow(value: value, clientUpdatedAt: at, deletedAt: nil,
                                                                  serverUpdatedAt: at.addingTimeInterval(5))])
        #expect(files.isEmpty, "no picture file is deleted")
        let row = try record(listing.id)
        #expect(row.photoFile == "a.jpg")
        #expect(row.dirty, "and it is still waiting to upload")
    }
}
