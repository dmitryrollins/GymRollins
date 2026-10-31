import Foundation
import GymCore
import GymData
import GymSync
import SwiftData
import Testing
@testable import GymRollins

/// Reports and blocks as the app runs them: the notice for a refused one, what sign-out says about the ones still
/// waiting, and the refresh a sent block asks for.
@MainActor
@Suite struct GymModerationEnvironmentTests {
    private func signedIn(_ stub: StubCatalogTransport) async throws -> SignedInGymRig {
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

    /// Someone else's shared listing, cached on this phone.
    private func strangersListing(_ env: AppEnvironment) throws -> GymListing {
        let gym = try env.gyms.addMapsGym(placeId: "P1", name: "Iron", address: nil, latitude: 1, longitude: 2)
        let made = try env.gyms.addListing(NewListing(gymId: gym.id, kindId: "flat-bench"))
        let id = made.id
        let row = try #require(try env.container.mainContext.fetch(
            FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first)
        row.visibilityRaw = GymVisibility.shared.rawValue
        row.uploadStateRaw = UploadState.uploaded.rawValue
        row.isOwn = false
        try env.container.mainContext.save()
        return made
    }

    @Test func aRefusedReportShowsItsNoticeOnce() async throws {
        let stub = StubCatalogTransport()
        stub.failure = .notAllowed
        let signedIn = try await signedIn(stub)
        let env = signedIn.env
        let listing = try strangersListing(env)

        try env.reportListing(listing.id, reason: .spam, note: nil)
        try await waitUntil { env.gymReportNotice != nil }

        #expect(env.gymReportNotice == "Couldn't send that report. Try again later.")
        #expect(env.gymSharing.outbox.takeReportNotice() == nil, "the outbox handed it over once")
        env.gymReportNotice = nil // the screen clears it when it goes away
        await env.runShareOutbox()
        #expect(env.gymReportNotice == nil, "nothing is shown again")
    }

    @Test func aReportThatWentThroughShowsNoNotice() async throws {
        let stub = StubCatalogTransport()
        let signedIn = try await signedIn(stub)
        let env = signedIn.env
        let listing = try strangersListing(env)
        try env.reportListing(listing.id, reason: .spam, note: nil)
        try await waitUntil { env.gymSharing.outbox.pendingCount == 0 }
        #expect(env.gymReportNotice == nil)
        #expect(stub.calls.contains("report"))
    }

    @Test func signOutCountsReportsThatCouldNotBeSent() async throws {
        let stub = StubCatalogTransport()
        stub.failure = .offline
        let signedIn = try await signedIn(stub)
        let env = signedIn.env
        let listing = try strangersListing(env)
        try env.reportListing(listing.id, reason: .spam, note: nil)

        let report = await env.prepareSignOut()

        #expect(report.unsentReports == 1)
        #expect(!report.isSafe)
        #expect(report.warning.hasSuffix("1 report hasn't been sent and will be lost."))
    }

    @Test func signOutSendsWhatItCanBeforeCountingAndIsSafeAfterwards() async throws {
        let stub = StubCatalogTransport()
        stub.failure = .offline
        let signedIn = try await signedIn(stub)
        let env = signedIn.env
        let listing = try strangersListing(env)
        try env.reportListing(listing.id, reason: .spam, note: nil)
        _ = await env.prepareSignOut()

        stub.failure = nil
        let report = await env.prepareSignOut()

        #expect(report.unsentReports == 0)
        #expect(stub.calls.contains("report"))
        #expect(env.gymSharing.outbox.pendingCount == 0)
    }

    @Test func theLastTryBeforeTheWipeSendsQueuedReportsToo() async throws {
        let stub = StubCatalogTransport()
        stub.failure = .offline
        let signedIn = try await signedIn(stub)
        let env = signedIn.env
        let listing = try strangersListing(env)
        try env.reportListing(listing.id, reason: .spam, note: nil)
        stub.failure = nil

        await env.sync.onWillSignOut()

        #expect(env.gymSharing.outbox.pendingCount == 0)
        #expect(stub.calls.contains("report"))
    }

    @Test func aSentBlockMakesTheGymOnScreenReadTheServerAgain() async throws {
        let stub = StubCatalogTransport()
        let serverGym = UUID()
        stub.gym = RemoteGym(id: serverGym, name: "Iron", address: nil, latitude: nil, longitude: nil, mapsPlaceId: "P1")
        func remote(_ id: UUID) -> RemoteListing {
            RemoteListing(id: id, gymId: serverGym, itemId: GymRepository.genericItemId(forKind: "flat-bench"),
                          kindId: "flat-bench", brand: nil, model: nil, photoPath: nil, loads: ListingLoads.none,
                          quantity: 1, notes: nil, status: "active", confirmCount: 1, isMine: false,
                          confirmedByMe: false)
        }
        let blocked = UUID(), sameAuthor = UUID()
        stub.listings = [remote(blocked), remote(sameAuthor)]
        let signedIn = try await signedIn(stub)
        let env = signedIn.env
        let gym = try env.gyms.addMapsGym(placeId: "P1", name: "Iron", address: nil, latitude: 1, longitude: 2)
        _ = env.setCurrentGym(gym.id)
        try await waitUntil { ((try? env.gyms.listings(gymId: gym.id).count) ?? 0) == 2 }

        try env.blockAuthor(ofListing: blocked)
        stub.listings = [] // the server now leaves out everything by that author
        try await waitUntil { ((try? env.gyms.listings(gymId: gym.id).count) ?? 1) == 0 }

        #expect(try env.gyms.listing(sameAuthor) == nil, "the author's other listing went at once, not after six hours")
    }
}
