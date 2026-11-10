import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@MainActor
@Suite struct GymEquipmentEnvironmentTests {
    private let photo = ProcessedGymPhoto(jpeg: Data("p".utf8), thumbnail: Data("t".utf8))

    @Test func removingAListingDeletesItsPhotoFiles() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gymWithPhoto()
        let listing = try #require(try rig.env.gyms.listings(gymId: gym.id).first)
        #expect(rig.photoCount() == 2)
        let before = rig.env.gymRevision
        try rig.env.removeListing(listing.id)
        #expect(try rig.env.gyms.listings(gymId: gym.id).isEmpty)
        #expect(rig.photoCount() == 0)
        #expect(rig.env.gymRevision == before + 1)
    }

    @Test func removingAListingWithoutAPhotoIsFine() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Plain", ["flat-bench": .none])
        let listing = try #require(try rig.env.gyms.listings(gymId: gym.id).first)
        try rig.env.removeListing(listing.id)
        #expect(try rig.env.gyms.listings(gymId: gym.id).isEmpty)
    }

    @Test func attachingAPhotoStoresItAndReplacesTheOldOne() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Plain", ["flat-bench": .none])
        let listing = try #require(try rig.env.gyms.listings(gymId: gym.id).first)
        try rig.env.attachPhoto(photo, to: listing.id)
        let first = try #require(try rig.env.gyms.listing(listing.id)?.photoFile)
        #expect(rig.photoCount() == 2)
        try rig.env.attachPhoto(photo, to: listing.id)
        let second = try #require(try rig.env.gyms.listing(listing.id)?.photoFile)
        #expect(second != first)
        #expect(rig.photoCount() == 2, "the replaced photo's files are gone")
    }

    @Test func aFailedAttachLeavesNoOrphanFile() throws {
        let rig = try GymTestRig.make()
        #expect(throws: GymDataError.self) { try rig.env.attachPhoto(photo, to: UUID()) }
        #expect(rig.photoCount() == 0)
    }
}
