import Foundation
import GymCore
import GymData
import GymSync
import Testing
import UIKit
@testable import GymRollins

/// Decision 9 in the app: a sign-out removes the picture files of the gym rows the server holds, and only those.
@MainActor
@Suite struct GymSignOutPhotosTests {
    private func savedPhoto(_ rig: GymTestRig) throws -> String {
        try rig.photos.save(ProcessedGymPhoto(jpeg: Data("p".utf8), thumbnail: Data("t".utf8)))
    }

    private func exists(_ rig: GymTestRig, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: rig.photos.url(name).path())
            || FileManager.default.fileExists(atPath: rig.photos.thumbnailURL(name).path())
    }

    private func markPushed(_ rig: GymTestRig) throws {
        let store = rig.env.syncStore
        for row in try store.dirtyGyms() {
            try store.markSynced(.gyms, id: row.value.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                                 serverUpdatedAt: Date())
        }
        for row in try store.dirtyGymListings() {
            try store.markSynced(.gymListings, id: row.value.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                                 serverUpdatedAt: Date())
        }
    }

    @Test func signOutDeletesTheFilesOfSyncedRowsAndKeepsThisPhoneOnlyOnes() async throws {
        let rig = try GymTestRig.make()
        let syncedFile = try savedPhoto(rig), deviceFile = try savedPhoto(rig)
        let synced = try rig.env.gyms.addPrivateGym(name: "Synced", address: nil)
        let listing = try rig.env.gyms.addListing(NewListing(gymId: synced.id, kindId: "dumbbells", photoFile: syncedFile))
        try rig.env.gyms.makeSynced(listing: listing.id)
        try markPushed(rig)
        let device = try rig.env.gyms.addPrivateGym(name: "Device", address: nil)
        try rig.env.gyms.addListing(NewListing(gymId: device.id, kindId: "dumbbells", photoFile: deviceFile))

        try await rig.env.sync.signOutAndRemoveLocalData()

        #expect(!exists(rig, syncedFile))
        #expect(exists(rig, deviceFile))
        #expect(try rig.env.gyms.gyms().map(\.name) == ["Device"])
        #expect(try rig.env.gyms.listings(gymId: device.id).first?.photoFile == deviceFile)
    }

    @Test func aSyncedRowThatNeverReachedTheServerKeepsItsFile() async throws {
        let rig = try GymTestRig.make()
        let file = try savedPhoto(rig)
        let gym = try rig.env.gyms.addPrivateGym(name: "Home", address: nil)
        let listing = try rig.env.gyms.addListing(NewListing(gymId: gym.id, kindId: "dumbbells", photoFile: file))
        try rig.env.gyms.makeSynced(listing: listing.id)

        try await rig.env.sync.signOutAndRemoveLocalData()

        #expect(exists(rig, file))
        #expect(try rig.env.gyms.listings(gymId: gym.id).first?.visibility == .device)
    }

    @Test func accountDeletionStillRemovesEveryGymAndPhoto() throws {
        let rig = try GymTestRig.make()
        _ = try rig.gymWithPhoto()
        try rig.env.eraseAllLocalData()
        #expect(rig.photoCount() == 0)
        #expect(try rig.env.gyms.gyms().isEmpty)
    }

    @Test func aDownloadedPictureIsSavedWithAThumbnailUnderTheNameSyncChose() throws {
        let rig = try GymTestRig.make()
        let size = CGSize(width: 800, height: 600)
        let jpeg = try #require(UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.orange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        })
        let name = "\(UUID().uuidString).jpg"
        try rig.photos.save(jpeg, file: name)
        #expect(rig.photos.data(file: name) == jpeg)
        #expect(FileManager.default.fileExists(atPath: rig.photos.thumbnailURL(name).path()))
        #expect(rig.photos.data(file: "../x.jpg") == nil)
        #expect(throws: GymPhotoStoreError.invalidFileName) { try rig.photos.save(jpeg, file: "../x.jpg") }
        try rig.photos.delete(file: name)
        #expect(rig.photos.data(file: name) == nil)
    }
}
