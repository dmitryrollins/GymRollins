import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymRollins

/// How a listing's sharing state reads on its tile, in its detail and on My gyms.
@MainActor
@Suite struct GymSharingStateTests {
    private func mapsGym(_ rig: GymTestRig) throws -> Gym {
        try rig.env.gyms.addMapsGym(placeId: "P1", name: "Iron", address: nil, latitude: 1, longitude: 2)
    }

    /// A listing in the given state, written the way the outbox and the cache write them.
    private func listing(_ rig: GymTestRig, gym: Gym, kind: String = "flat-bench", visibility: GymVisibility = .device,
                         upload: UploadState = .local, own: Bool = true, confirms: Int = 0, confirmedByMe: Bool = false,
                         status: ListingStatus = .active, error: String? = nil) throws -> GymListing {
        let made = try rig.env.gyms.addListing(NewListing(gymId: gym.id, kindId: kind))
        let id = made.id
        let context = rig.env.container.mainContext
        let row = try #require(try context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first)
        row.visibilityRaw = visibility.rawValue
        row.uploadStateRaw = upload.rawValue
        row.isOwn = own
        row.confirmCount = confirms
        row.confirmedByMe = confirmedByMe
        row.statusRaw = status.rawValue
        row.uploadError = error
        try context.save()
        return try #require(try rig.env.gyms.listing(id))
    }

    // MARK: Badges

    @Test func eachStateHasItsBadge() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        func badge(_ l: GymListing) -> String? { GymEquipmentModel.ListingBadge(l)?.text }
        #expect(badge(try listing(rig, gym: gym)) == "Only me")
        #expect(badge(try listing(rig, gym: gym, visibility: .synced, upload: .local)) == "Synced")
        #expect(badge(try listing(rig, gym: gym, visibility: .shared, upload: .queued)) == "Waiting to upload")
        #expect(badge(try listing(rig, gym: gym, visibility: .device, upload: .failed)) == "Couldn't upload")
        #expect(badge(try listing(rig, gym: gym, visibility: .shared, upload: .uploaded, own: false, confirms: 3))
                    == "\u{2713} 3")
        #expect(badge(try listing(rig, gym: gym, visibility: .shared, upload: .uploaded, own: false)) == nil)
        #expect(badge(try listing(rig, gym: gym, visibility: .shared, upload: .waitingForChoice)) == "Needs a choice")
    }

    @Test func aQueuedOrFailedShareWinsOverTheConfirmCount() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        let failed = try listing(rig, gym: gym, visibility: .device, upload: .failed, confirms: 2)
        #expect(GymEquipmentModel.ListingBadge(failed)?.text == "Couldn't upload")
    }

    @Test func aRowFromANewerAppSaysToUpdateAndSitsInOther() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        _ = try listing(rig, gym: gym, kind: "lat-pulldown", visibility: .shared, upload: .uploaded, own: false,
                        status: .unsupported)
        let shown = try rig.env.gyms.listings(gymId: gym.id, includingUnsupported: true)
        let model = GymEquipmentModel(gym: gym, listings: shown, catalog: rig.env.gymCatalog, unit: .lb, coverage: [])
        let tile = try #require(model.sections.first?.tiles.first)
        #expect(model.sections.map(\.title) == [GymEquipmentModel.unknownSectionTitle])
        #expect(tile.title == GymEquipmentModel.unknownKindTitle)
        #expect(tile.loadsText == nil && tile.brandAndModel == nil)
    }

    @Test func myOwnFlaggedListingStaysOnTheScreenWithItsBadgeButOutOfTheRules() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        let flagged = try listing(rig, gym: gym, visibility: .shared, upload: .uploaded, status: .flagged)
        _ = try listing(rig, gym: gym, kind: "lat-pulldown", visibility: .shared, upload: .uploaded, own: false,
                        status: .flagged)
        let shown = try rig.env.gyms.listings(gymId: gym.id, includingUnsupported: true)
        #expect(shown.map(\.id) == [flagged.id], "only my own flagged row is listed")
        let model = GymEquipmentModel(gym: gym, listings: shown, catalog: rig.env.gymCatalog, unit: .lb, coverage: [])
        #expect(model.sections.first?.tiles.first?.badge?.text == "Under review")
        #expect(try rig.env.gyms.listings(gymId: gym.id).isEmpty, "the default list is what the rules use")
        #expect(try rig.env.gyms.inventory(gymId: gym.id).listings.isEmpty)
    }

    @Test func myOwnFlaggedListingSaysUnderReviewInItsDetail() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        let flagged = try listing(rig, gym: gym, visibility: .shared, upload: .uploaded, status: .flagged)
        let status = ShareStatusModel(listing: flagged, gym: gym)
        #expect(status.text == "Under review")
        #expect(status.actions.isEmpty)
    }

    @Test func aReportedListingLeavesEveryListButStaysOnThePhoneForTheQueue() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        let theirs = try listing(rig, gym: gym, kind: "lat-pulldown", visibility: .shared, upload: .uploaded, own: false)
        let context = rig.env.container.mainContext
        let id = theirs.id
        try #require(try context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first)
            .hiddenLocally = true
        try context.save()
        #expect(try rig.env.gyms.listings(gymId: gym.id, includingUnsupported: true).isEmpty)
        #expect(try rig.env.gyms.listing(id) == nil)
        #expect(try rig.env.gyms.inventory(gymId: gym.id).listings.isEmpty)
        #expect(try rig.env.gyms.itemCounts()[gym.id] == nil)
    }

    // MARK: Status row

    @Test func aPhoneOnlyListingAtAMapsGymOffersSharing() throws {
        let rig = try GymTestRig.make()
        let status = ShareStatusModel(listing: try listing(rig, gym: try mapsGym(rig)), gym: try mapsGym(rig))
        #expect(status.text == "Only me")
        #expect(status.actions == [.share])
    }

    @Test func aPhoneOnlyListingAtAPrivateGymOffersToSyncIt() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Home")
        let status = ShareStatusModel(listing: try listing(rig, gym: gym), gym: gym)
        #expect(status.text == "Only me")
        #expect(status.actions == [.sync])
        #expect(ShareStatusModel.title(.sync) == "Sync to my account")
        #expect(ShareStatusModel.identifier(.sync) == "listing.sync")
    }

    @Test func aPhoneOnlyListingAtAnAlreadySyncedGymCanStillBeSynced() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Home")
        try rig.env.gyms.makeSynced(gym: gym.id)
        let synced = try #require(try rig.env.gyms.gym(gym.id))
        let status = ShareStatusModel(listing: try listing(rig, gym: synced), gym: synced)
        #expect(status.actions == [.sync], "the gym is synced but this one never left the phone")
    }

    @Test func aSyncedListingOffersNoSync() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Home")
        #expect(ShareStatusModel(listing: try listing(rig, gym: gym, visibility: .synced), gym: gym).actions.isEmpty)
    }

    @Test func aFailedShareGivesTheReasonAndRetry() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        let failed = try listing(rig, gym: gym, upload: .failed, error: "This gym is under review. Try again later.")
        let status = ShareStatusModel(listing: failed, gym: gym)
        #expect(status.text == "Couldn't upload")
        #expect(status.reason == "This gym is under review. Try again later.")
        #expect(status.actions == [.retry])
    }

    @Test func aQueuedShareJustWaits() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        let status = ShareStatusModel(listing: try listing(rig, gym: gym, visibility: .shared, upload: .queued), gym: gym)
        #expect(status.text == "Waiting to upload")
        #expect(status.actions.isEmpty)
    }

    @Test func someoneElsesListingOffersAConfirmUntilIHaveConfirmedIt() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        let open = try listing(rig, gym: gym, visibility: .shared, upload: .uploaded, own: false, confirms: 2)
        let done = try listing(rig, gym: gym, visibility: .shared, upload: .uploaded, own: false, confirms: 3,
                               confirmedByMe: true)
        #expect(ShareStatusModel(listing: open, gym: gym).actions == [.confirm])
        let confirmed = ShareStatusModel(listing: done, gym: gym)
        #expect(confirmed.actions.isEmpty)
        #expect(confirmed.text == "You confirmed this")
    }

    @Test func myOwnSharedListingCannotBeConfirmedByMe() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        let mine = try listing(rig, gym: gym, visibility: .shared, upload: .uploaded, own: true, confirms: 2)
        let status = ShareStatusModel(listing: mine, gym: gym)
        #expect(status.text == "Shared at this gym")
        #expect(status.actions.isEmpty)
    }

    @Test func aListingWaitingForAChoiceSaysTheGymMayHaveIt() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        let waiting = try listing(rig, gym: gym, visibility: .shared, upload: .waitingForChoice)
        let status = ShareStatusModel(listing: waiting, gym: gym)
        #expect(status.text == "This gym may already have it")
        #expect(status.actions == [.shareAnyway])
    }

    @Test func aSyncedListingSaysSo() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Home")
        let status = ShareStatusModel(listing: try listing(rig, gym: gym, visibility: .synced), gym: gym)
        #expect(status.text == "Synced to your account")
    }

    @Test func removingIsOfferedForAShareThatHasNotReachedTheServer() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        for state in [UploadState.queued, .failed, .waitingForChoice] {
            let waiting = try listing(rig, gym: gym, visibility: .shared, upload: state)
            #expect(ShareStatusModel(listing: waiting, gym: gym).canRemove, "\(state) can be taken back")
        }
        let someoneElses = try listing(rig, gym: gym, visibility: .shared, upload: .queued, own: false)
        #expect(!ShareStatusModel(listing: someoneElses, gym: gym).canRemove)
    }

    @Test func theDeleteCopySaysWhatReallyHappens() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        func message(_ l: GymListing) -> String { ShareStatusModel(listing: l, gym: gym).deleteMessage }
        #expect(message(try listing(rig, gym: gym)) == "It and its photo will be deleted from this phone. This can't be undone.")
        #expect(message(try listing(rig, gym: gym, visibility: .synced))
                == "It and its photo will be deleted from this phone and your account. This can't be undone.")
        let notShared = "It and its photo will be deleted from this phone and won't be shared."
        #expect(message(try listing(rig, gym: gym, visibility: .shared, upload: .queued)) == notShared)
        #expect(message(try listing(rig, gym: gym, visibility: .shared, upload: .failed)) == notShared)
        #expect(message(try listing(rig, gym: gym, visibility: .shared, upload: .waitingForChoice)) == notShared)
        #expect(message(try listing(rig, gym: gym, visibility: .device, upload: .failed)) == notShared)
    }

    @Test func removingIsOfferedOnlyForListingsThatStayOnTheAccountOrPhone() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        #expect(ShareStatusModel(listing: try listing(rig, gym: gym), gym: gym).canRemove)
        #expect(ShareStatusModel(listing: try listing(rig, gym: gym, upload: .failed), gym: gym).canRemove)
        #expect(!ShareStatusModel(listing: try listing(rig, gym: gym, visibility: .shared, upload: .uploaded, own: false),
                                  gym: gym).canRemove, "someone else's")
        #expect(!ShareStatusModel(listing: try listing(rig, gym: gym, visibility: .shared, upload: .uploaded),
                                  gym: gym).canRemove, "my own shared one waits for plan 22")
    }

    @Test func sharedListingsAreReadOnly() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        #expect(ShareStatusModel(listing: try listing(rig, gym: gym), gym: gym).canEdit)
        #expect(!ShareStatusModel(listing: try listing(rig, gym: gym, visibility: .shared, upload: .uploaded, own: false),
                                  gym: gym).canEdit)
    }
}
