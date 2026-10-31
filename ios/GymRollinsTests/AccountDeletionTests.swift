import Foundation
import GymData
import GymSync
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

    @Test func deleteAccountPassesThePortThatRemovesThePhotos() async throws {
        let stub = StubCatalogTransport()
        let rig = try rig(stub: stub)
        var called = false
        var received: (@Sendable (UUID) async throws -> Void)?
        rig.env.sync.deleteOnServer = { port in
            called = true
            received = port
        }

        try await rig.env.sync.deleteAccount()

        #expect(called)
        let port = try #require(received, "the server step got no photo port")
        #expect(stub.calls.isEmpty, "nothing is removed until the server step asks")
        try await port(UUID())
        #expect(stub.calls == ["deleteAllPhotos"])
    }

    @Test func aRefusedDeletionWipesNothingOnThePhone() async throws {
        let rig = try rig(stub: StubCatalogTransport())
        try rig.gym("Home")
        var wiped = false
        rig.env.sync.onLocalDataReset = { wiped = true }
        rig.env.sync.deleteOnServer = { _ in throw AuthFailure(message: "Couldn't remove your photos, so your account hasn't been deleted.") }

        await #expect(throws: AuthFailure.self) { try await rig.env.sync.deleteAccount() }

        #expect(!wiped)
        #expect(try rig.env.gyms.gyms().count == 1, "the phone's gyms are still there")
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
        #expect(UnblockEveryoneRow.errorText(GymCatalogError.rejected("sql blew up"))
            == "Couldn't unblock right now. Please try again.")
    }

    @Test func theContactRowShowsOnlyWithAnAddress() {
        #expect(ContentContactRow.label(for: nil) == nil)
        #expect(ContentContactRow.label(for: "") == nil)
        #expect(ContentContactRow.label(for: "help@example.com") == "Report a content problem: help@example.com")
        #expect(ContentContactRow.url(for: "help@example.com")?.absoluteString == "mailto:help@example.com")
        #expect(GymConstants.contentContactEmail == nil, "the owner sets the address before launch")
    }
}
