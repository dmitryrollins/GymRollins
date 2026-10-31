import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// What the review of plan 22 found in the queue and the cache: hidden rows that stay hidden, blocks that don't
/// refresh, and an unblock that races a queued block.
@MainActor
@Suite struct ShareOutboxModerationFixTests: ReportsTestRig {
    let f: SyncFixture
    let transport = FakeGymCatalogTransport()
    let serverGymId = UUID()
    let user = UUID()
    init() throws { f = try SyncFixture() }

    private func stamp(_ gym: Gym) throws -> Date? { try #require(try repo.gymRecord(gym.id)).catalogRefreshedAt }

    @Test func aSentBlockMakesTheNextOpenReadTheServerEvenInsideTheInterval() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = remote(), sameAuthor = remote()
        try await cache(gym, [a, sameAuthor])
        let box = outbox
        try box.enqueueBlock(listingId: a.id, ownerId: user)
        await box.run(userId: user)
        #expect(try stamp(gym) == nil)
        try await cache(gym, [], force: false) // the server now leaves out everything by that author
        #expect(try shown(gym).isEmpty, "the author's other listings go at the next open, not after six hours")
    }

    @Test func aBlockStillQueuedLeavesTheStampAlone() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        try await cache(gym, [remote()])
        let box = outbox
        transport.failingCalls = ["blockAuthor"]
        try box.enqueueBlock(listingId: try #require(try repo.listings(gymId: gym.id).first).id, ownerId: user)
        await box.run(userId: user)
        #expect(try stamp(gym) != nil)
    }

    @Test func aListingThatTurnsOutToBeYoursStopsHidingAfterTheReportWasQueuedSignedOut() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let id = UUID()
        try await cache(gym, [remote(id, mine: false)]) // read while signed out: not mine
        let box = outbox
        try box.enqueueReport(listingId: id, reason: .spam, note: nil, ownerId: user)
        transport.ownTargets = [id]
        await box.run(userId: user)
        try await cache(gym, [remote(id, mine: true)]) // the first refresh signed in
        #expect(try shown(gym) == [id])
        let row = try #require(try repo.listingRecord(id))
        #expect(row.isOwn && !row.hiddenLocally && !row.hiddenByBlock)
    }

    @Test func aQueuedReportDoesNotHideARowTheServerSaysIsYours() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let id = UUID()
        try await cache(gym, [remote(id, mine: false)])
        let box = outbox
        transport.failingCalls = ["report"]
        try box.enqueueReport(listingId: id, reason: .spam, note: nil, ownerId: user)
        await box.run(userId: user)
        try await cache(gym, [remote(id, mine: true)])
        #expect(try shown(gym) == [id])
    }

    @Test func aListingReportJoiningAQueuedPhotoReportIsItsOwnRow() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let source = UUID()
        try await cache(gym, [remote(source)])
        let (mine, _) = try borrowed(gym, source: source)
        let box = outbox
        try box.enqueueCataloguePhotoReport(listingId: mine.id, reason: .personInPhoto, note: nil, ownerId: user)
        try box.enqueueReport(listingId: source, reason: .spam, note: "second", ownerId: user)
        #expect(box.pendingCount == 2, "the second report is about the listing, not the picture")
        transport.reportScript = [.dailyLimit]
        await box.run(userId: user)
        #expect(box.pendingCount == 0)
        #expect(try shown(gym) == [mine.id], "the listing report went through, so the source stays hidden")
        #expect(transport.reports.map(\.note) == [nil, "second"])
    }

    @Test func aBlockedRowThatComesBackWhileTheBlockWaitsIsStillUndoneByUnblock() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = remote(), b = remote()
        try await cache(gym, [a, b])
        let box = outbox
        transport.failingCalls = ["blockAuthor"]
        try box.enqueueBlock(listingId: a.id, ownerId: user)
        await box.run(userId: user)
        try await cache(gym, [b])
        try await cache(gym, [a, b])
        let row = try #require(try repo.listingRecord(a.id))
        #expect(row.hiddenLocally && row.hiddenByBlock, "it comes back hidden, and as a block's doing")
        transport.failingCalls = []
        _ = try await box.unblockAll()
        try await cache(gym, [a, b])
        #expect(try shown(gym) == [a.id, b.id])
    }

    @Test func aQueuedBlockDoesNotGoOutWhileTheUnblockIsOnTheWire() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = remote()
        try await cache(gym, [a])
        let gated = GatedGymCatalogTransport()
        let box = ShareOutbox(repository: repo, transport: gated, photoData: { _ in nil },
                              now: { [clock = f.clock] in clock.now })
        try box.enqueueBlock(listingId: a.id, ownerId: user)
        gated.hold("unblockAll")
        let undo = Task { try await box.unblockAll() }
        await gated.waitUntilSuspended("unblockAll")
        await box.run(userId: user)
        gated.release()
        _ = try await undo.value
        #expect(gated.inner.blocks.isEmpty, "the user asked to unblock; a block sent now would undo it")
        #expect(box.pendingCount == 0, "and the block row is gone once the unblock returns")
        #expect(try shown(gym) == [a.id])
    }

    @Test func aBlockQueuedAfterTheUnblockReturnsStillGoesOut() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = remote()
        try await cache(gym, [a])
        let box = outbox
        _ = try await box.unblockAll()
        try box.enqueueBlock(listingId: a.id, ownerId: user)
        await box.run(userId: user)
        #expect(transport.blocks == [.init(type: .listing, id: a.id)])
    }

    @Test func choosingTheExistingListingShowsItAgainIfTheUserHadReportedIt() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let existing = remote()
        try await cache(gym, [existing])
        let box = outbox
        transport.failingCalls = ["report"]
        try box.enqueueReport(listingId: existing.id, reason: .duplicate, note: nil, ownerId: user)
        let mine = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        _ = try box.keepExisting(listingId: mine.id, existingId: existing.id, ownerId: user)
        #expect(try shown(gym) == [existing.id], "the user just said it is the same machine")
        try await cache(gym, [existing])
        #expect(try shown(gym) == [existing.id], "and the queued report doesn't hide it again")
        transport.failingCalls = []
        await box.run(userId: user)
        #expect(transport.reports.count == 1, "the report itself still goes out")
    }
}
