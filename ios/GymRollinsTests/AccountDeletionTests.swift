import Foundation
import GymData
import GymSync
import SwiftData
import Testing
@testable import GymRollins

/// What the app does around account deletion: it hands the server step the photo port, wipes nothing until the server
/// says yes, and words what the user sees.
@MainActor
@Suite struct AccountDeletionTests {
    private func rig(stub: StubCatalogTransport) throws -> GymTestRig {
        let rig = try GymTestRig.make()
        rig.env.gymSharing = GymSharing(
            repository: rig.env.gyms, transport: stub, knownKinds: ["flat-bench"],
            photos: GymPhotoCache(store: rig.photos) { _, _ in Data() }, photoData: { rig.photos.data(file: $0) },
            now: rig.env.now)
        rig.env.wireGymSharing()
        return rig
    }

    /// A signed-in phone whose catalogue is `stub`.
    private func signedIn(stub: StubCatalogTransport) async throws -> SignedInGymRig {
        let signedIn = try SignedInGymRig.make()
        let env = signedIn.env
        env.gymSharing = GymSharing(
            repository: env.gyms, transport: stub, knownKinds: ["flat-bench"],
            photos: GymPhotoCache(store: signedIn.rig.photos) { _, _ in Data() },
            photoData: { signedIn.rig.photos.data(file: $0) }, now: env.now)
        env.wireGymSharing()
        try await signedIn.signIn(as: signedIn.userA)
        return signedIn
    }

    /// A synced listing with a picture on the phone and on the server, as a lifter with shared-looking data has.
    private func uploadedListing(_ env: AppEnvironment) throws -> UUID {
        let gym = try env.gyms.addPrivateGym(name: "Home", address: nil)
        let listing = try env.gyms.addListing(NewListing(gymId: gym.id, kindId: "flat-bench", photoFile: "p.jpg"))
        try env.gyms.makeSynced(listing: listing.id)
        try env.syncStore.setRemotePhotoPath(listingId: listing.id, path: "old.jpg")
        return listing.id
    }

    private func record(_ env: AppEnvironment, _ id: UUID) throws -> GymListingRecord {
        try #require(try env.container.mainContext.fetch(
            FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first)
    }

    private func remotePath(_ env: AppEnvironment, _ id: UUID) throws -> String? {
        try record(env, id).remotePhotoPath
    }

    @Test func deleteAccountPassesStepsThatDetachThenRemove() async throws {
        let stub = StubCatalogTransport()
        let rig = try rig(stub: stub)
        var received: AccountPhotoSteps?
        rig.env.sync.deleteOnServer = { steps in received = steps }

        try await rig.env.sync.deleteAccount()

        let steps = try #require(received, "the server step got no photo steps")
        #expect(stub.calls.isEmpty, "nothing is removed until the server step asks")
        try await steps.detach()
        try await steps.remove()
        #expect(stub.calls == ["detachAllPhotos", "deleteAllPhotos"])
    }

    @Test func aFailedDetachLeavesTheStoreAlone() async throws {
        let stub = StubCatalogTransport()
        stub.detachFailure = .offline
        let signedIn = try await signedIn(stub: stub)
        let id = try uploadedListing(signedIn.env)
        signedIn.env.sync.deleteOnServer = { steps in try await steps?.detach(); try await steps?.remove() }

        await #expect(throws: GymCatalogError.offline) { try await signedIn.env.sync.deleteAccount() }

        #expect(try remotePath(signedIn.env, id) == "old.jpg", "the server still names it, so the phone does too")
        #expect(!stub.calls.contains("deleteAllPhotos"))
    }

    @Test func aRefusalAfterThePhotosGoLeavesThePhoneForgettingTheNames() async throws {
        let stub = StubCatalogTransport()
        let signedIn = try await signedIn(stub: stub)
        let id = try uploadedListing(signedIn.env)
        var wiped = false
        signedIn.env.sync.onLocalDataReset = { wiped = true }
        signedIn.env.sync.deleteOnServer = { steps in
            try await steps?.detach()
            try await steps?.remove()
            throw AuthFailure(message: "Your photos were removed, but your account wasn't deleted.")
        }

        await #expect(throws: AuthFailure.self) { try await signedIn.env.sync.deleteAccount() }

        #expect(stub.calls.prefix(2) == ["detachAllPhotos", "deleteAllPhotos"])
        #expect(try remotePath(signedIn.env, id) == nil, "so the next sync uploads the picture again")
        #expect(try record(signedIn.env, id).dirty)
        #expect(try record(signedIn.env, id).photoFile == "p.jpg")
        #expect(!wiped)
    }

    @Test func aRefusedDeletionWipesNothingOnThePhone() async throws {
        let stub = StubCatalogTransport()
        let signedIn = try await signedIn(stub: stub)
        let env = signedIn.env
        try signedIn.rig.gym("Home")
        await env.refreshGymAdmin()
        #expect(env.gymAdmin.isAdmin)
        try env.gymSharing.outbox.enqueueConfirm(listingId: UUID(), ownerId: signedIn.userA)
        var wiped = false
        env.sync.onLocalDataReset = { wiped = true }
        env.sync.deleteOnServer = { _ in throw AuthFailure(message: "Couldn't delete your account.") }

        await #expect(throws: AuthFailure.self) { try await env.sync.deleteAccount() }

        #expect(!wiped)
        #expect(try env.gyms.gyms().count == 1, "the phone's gyms are still there")
        #expect(env.gymAdmin.isAdmin, "the session goes on, so the Moderation row stays")
        try await waitUntil { env.gymSharing.outbox.pendingCount == 0 }
        #expect(stub.calls.contains("confirm"), "and the queue runs again")
    }

    @Test func aDeletionThatSucceedsEndsTheAdminStatusWithTheSession() async throws {
        let signedIn = try await signedIn(stub: StubCatalogTransport())
        await signedIn.env.refreshGymAdmin()
        #expect(signedIn.env.gymAdmin.isAdmin)
        signedIn.env.sync.deleteOnServer = { _ in }

        try await signedIn.env.sync.deleteAccount()

        #expect(!signedIn.env.gymAdmin.isAdmin)
    }

    @Test func nothingUploadsWhileTheAccountIsBeingDeleted() async throws {
        let stub = StubCatalogTransport()
        let signedIn = try await signedIn(stub: stub)
        let env = signedIn.env
        try env.gymSharing.outbox.enqueueConfirm(listingId: UUID(), ownerId: signedIn.userA)
        env.sync.deleteOnServer = { _ in
            await env.runShareOutbox()
            throw AuthFailure(message: "refused")
        }
        await #expect(throws: AuthFailure.self) { try await env.sync.deleteAccount() }
        #expect(!stub.calls.contains("confirm"), "the run during the deletion did nothing")
    }

    @Test func aSuccessfulDeletionWipesThePhone() async throws {
        let rig = try rig(stub: StubCatalogTransport())
        try rig.gym("Home")
        var wiped = false
        rig.env.sync.onLocalDataReset = { wiped = true }
        rig.env.sync.deleteOnServer = { _ in }

        try await rig.env.sync.deleteAccount()

        #expect(wiped)
        #expect(try rig.env.gyms.gyms().isEmpty)
    }

    @Test func unblockResultsReadForOneNoneAndMany() {
        #expect(UnblockEveryoneRow.resultText(count: 0) == "No one was blocked.")
        #expect(UnblockEveryoneRow.resultText(count: 1) == "Unblocked 1 person.")
        #expect(UnblockEveryoneRow.resultText(count: 2) == "Unblocked 2 people.")
    }

    @Test func unblockErrorsAreShortAndPlain() {
        #expect(UnblockEveryoneRow.errorText(GymCatalogError.offline).contains("Check your connection"))
        #expect(UnblockEveryoneRow.errorText(GymCatalogError.signedOut) == "Sign in to unblock people.")
        #expect(UnblockEveryoneRow.errorText(GymCatalogError.dailyLimit)
            == "You've unblocked people a few times today. Try again tomorrow.")
        #expect(UnblockEveryoneRow.errorText(GymCatalogError.rejected("sql blew up"))
            == "Couldn't unblock right now. Please try again.")
    }

    @Test func theContactRowShowsOnlyWithAnAddress() {
        #expect(ContentContactRow.label(for: nil) == nil)
        #expect(ContentContactRow.label(for: "") == nil)
        #expect(ContentContactRow.label(for: "help@example.com") == "Report a content problem: help@example.com")
        #expect(ContentContactRow.url(for: "help@example.com")?.absoluteString == "mailto:help@example.com")
    }
}
