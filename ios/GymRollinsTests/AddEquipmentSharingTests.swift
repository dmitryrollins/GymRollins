import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymRollins

/// Steps 3 and 4 of the add flow once a gym can be shared: who is asked to sign in, what is queued, and what stays put.
@MainActor
@Suite struct AddEquipmentSharingTests {
    private let user = UUID()

    /// What the flow asked of the environment, in order.
    @MainActor
    final class Calls {
        var signedIn: UUID?
        var shared: [UUID] = []
        var synced: [UUID] = []
        var confirmed: [UUID] = []
        var order: [String] = []
        var remoteItems: [CatalogueItem] = []
    }

    private func model(_ rig: GymTestRig, gym: Gym, calls: Calls) -> AddEquipmentModel {
        let repo = rig.env.gyms
        var ports = AddEquipmentModel.Ports(
            listings: { kindId in try repo.listings(gymId: gym.id).filter { $0.item.kindId == kindId } },
            catalogueItems: { try repo.catalogueItems(kindId: $0) },
            savePhoto: { try rig.photos.save($0) }, deletePhoto: { try? rig.photos.delete($0) },
            addListing: { calls.order.append("add"); return try repo.addListing($0) },
            attachPhoto: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        ports.signedInUser = { calls.signedIn }
        ports.shareListing = { calls.shared.append($0) }
        ports.syncListing = { calls.synced.append($0) }
        ports.confirmListing = { calls.confirmed.append($0) }
        ports.items = { _ in calls.remoteItems }
        ports.upsertItem = { _ in calls.order.append("upsert") }
        return AddEquipmentModel(gym: gym, catalog: rig.env.gymCatalog, unit: .lb, ports: ports)
    }

    private func mapsGym(_ rig: GymTestRig) throws -> Gym {
        try rig.env.gyms.addMapsGym(placeId: "P1", name: "Iron", address: nil, latitude: 1, longitude: 2)
    }

    /// Someone else's listing, as a refresh caches it.
    @discardableResult
    private func cachedByOthers(_ rig: GymTestRig, gym: Gym, kind: String, confirms: Int = 3,
                                confirmedByMe: Bool = false) throws -> GymListing {
        let listing = try rig.env.gyms.addListing(NewListing(gymId: gym.id, kindId: kind, loads: .none))
        let id = listing.id
        let row = try #require(try rig.env.container.mainContext.fetch(
            FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first)
        row.isOwn = false
        row.visibilityRaw = GymVisibility.shared.rawValue
        row.uploadStateRaw = UploadState.uploaded.rawValue
        row.confirmCount = confirms
        row.confirmedByMe = confirmedByMe
        try rig.env.container.mainContext.save()
        return try #require(try rig.env.gyms.listing(id))
    }

    private func toDetails(_ flow: AddEquipmentModel, kind: String = "lat-pulldown") {
        flow.skipPhoto()
        flow.chooseKind(kind)
        if flow.step == .duplicate { flow.different() }
    }

    // MARK: Step 4

    @Test func aMapsGymOffersSharingAndAPrivateGymOffersSync() throws {
        let rig = try GymTestRig.make()
        let calls = Calls()
        let maps = model(rig, gym: try mapsGym(rig), calls: calls)
        let privateGym = model(rig, gym: try rig.gym("Home"), calls: calls)
        #expect(maps.visibilityOptions == [.device, .shared])
        #expect(privateGym.visibilityOptions == [.device, .synced])
        #expect(maps.visibility == .device && privateGym.visibility == .device, "this phone only is the default")
    }

    @Test func savingOnThisPhoneNeverAsksOrCallsTheServer() throws {
        let rig = try GymTestRig.make()
        let calls = Calls()
        let flow = model(rig, gym: try mapsGym(rig), calls: calls)
        toDetails(flow)
        flow.save()
        #expect(!flow.signInNeeded)
        guard case .created? = flow.outcome else { Issue.record("not saved"); return }
        #expect(calls.shared.isEmpty && calls.synced.isEmpty)
    }

    @Test func aSignedOutShareAsksForSignInAndSavesNothing() throws {
        let rig = try GymTestRig.make()
        let calls = Calls()
        let gym = try mapsGym(rig)
        let flow = model(rig, gym: gym, calls: calls)
        toDetails(flow)
        flow.visibility = .shared
        flow.save()
        #expect(flow.signInNeeded)
        #expect(flow.outcome == nil)
        #expect(try rig.env.gyms.listings(gymId: gym.id).isEmpty)
        flow.signInCancelled()
        #expect(!flow.signInNeeded && flow.step == .details)
        #expect(try rig.env.gyms.listings(gymId: gym.id).isEmpty, "cancelling queues and saves nothing")
        #expect(calls.shared.isEmpty)
    }

    @Test func aSignedInShareSavesThenQueuesAndFinishes() throws {
        let rig = try GymTestRig.make()
        let calls = Calls()
        calls.signedIn = user
        let flow = model(rig, gym: try mapsGym(rig), calls: calls)
        toDetails(flow)
        flow.visibility = .shared
        flow.save()
        guard case let .created(listing)? = flow.outcome else { Issue.record("not saved"); return }
        #expect(calls.shared == [listing.id])
        #expect(!flow.signInNeeded)
    }

    @Test func signingInContinuesTheSave() throws {
        let rig = try GymTestRig.make()
        let calls = Calls()
        let flow = model(rig, gym: try mapsGym(rig), calls: calls)
        toDetails(flow)
        flow.visibility = .shared
        flow.save()
        #expect(flow.signInNeeded)
        calls.signedIn = user
        flow.signInFinished()
        guard case let .created(listing)? = flow.outcome else { Issue.record("not saved"); return }
        #expect(calls.shared == [listing.id])
    }

    @Test func aSignInThatLeavesNobodySignedInSavesNothing() throws {
        let rig = try GymTestRig.make()
        let calls = Calls()
        let flow = model(rig, gym: try mapsGym(rig), calls: calls)
        toDetails(flow)
        flow.visibility = .shared
        flow.save()
        flow.signInFinished()
        #expect(flow.outcome == nil && calls.shared.isEmpty)
        #expect(flow.errorText != nil)
    }

    @Test func syncedNeedsSignInThenMarksTheListingSynced() throws {
        let rig = try GymTestRig.make()
        let calls = Calls()
        let flow = model(rig, gym: try rig.gym("Home"), calls: calls)
        toDetails(flow)
        flow.visibility = .synced
        flow.save()
        #expect(flow.signInNeeded && calls.synced.isEmpty)
        calls.signedIn = user
        flow.signInFinished()
        guard case let .created(listing)? = flow.outcome else { Issue.record("not saved"); return }
        #expect(calls.synced == [listing.id])
    }

    // MARK: Step 3

    @Test func othersListingsComeFirstAndOwnShowsAlreadyAdded() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        let own = try rig.env.gyms.addListing(NewListing(gymId: gym.id, kindId: "lat-pulldown",
                                                         loads: .stack(maxKg: 90, stepKg: nil)))
        let few = try cachedByOthers(rig, gym: gym, kind: "lat-pulldown", confirms: 1)
        let many = try cachedByOthers(rig, gym: gym, kind: "lat-pulldown", confirms: 5)
        let flow = model(rig, gym: gym, calls: Calls())
        flow.skipPhoto()
        flow.chooseKind("lat-pulldown")
        #expect(flow.step == .duplicate)
        #expect(flow.existing.map(\.id) == [many.id, few.id, own.id])
        #expect(flow.isAlreadyAdded(own) && !flow.isAlreadyAdded(many))
        #expect(!flow.canConfirm(own) && flow.canConfirm(many))
    }

    @Test func aListingIAlreadyConfirmedOffersNoSecondConfirm() throws {
        let rig = try GymTestRig.make()
        let gym = try mapsGym(rig)
        let done = try cachedByOthers(rig, gym: gym, kind: "lat-pulldown", confirmedByMe: true)
        let flow = model(rig, gym: gym, calls: Calls())
        flow.skipPhoto()
        flow.chooseKind("lat-pulldown")
        #expect(!flow.canConfirm(done))
        #expect(flow.hasConfirmed(done))
    }

    @Test func aSignedOutConfirmAsksForSignInAndQueuesNothing() throws {
        let rig = try GymTestRig.make()
        let calls = Calls()
        let gym = try mapsGym(rig)
        let theirs = try cachedByOthers(rig, gym: gym, kind: "lat-pulldown")
        let flow = model(rig, gym: gym, calls: calls)
        flow.skipPhoto()
        flow.chooseKind("lat-pulldown")
        flow.confirmExisting(theirs)
        #expect(flow.signInNeeded && flow.outcome == nil)
        flow.signInCancelled()
        #expect(calls.confirmed.isEmpty && flow.outcome == nil && flow.step == .duplicate)
    }

    @Test func aSignedInConfirmQueuesAndClosesTheFlow() throws {
        let rig = try GymTestRig.make()
        let calls = Calls()
        calls.signedIn = user
        let gym = try mapsGym(rig)
        let theirs = try cachedByOthers(rig, gym: gym, kind: "lat-pulldown")
        let flow = model(rig, gym: gym, calls: calls)
        flow.photoProcessed(GymPhotoFixtureValue.photo)
        flow.chooseKind("lat-pulldown")
        flow.confirmExisting(theirs)
        #expect(calls.confirmed == [theirs.id])
        #expect(flow.outcome == .confirmed(theirs))
        #expect(rig.photoCount() == 0, "the user's photo isn't put on someone else's listing")
    }

    @Test func signingInContinuesTheConfirm() throws {
        let rig = try GymTestRig.make()
        let calls = Calls()
        let gym = try mapsGym(rig)
        let theirs = try cachedByOthers(rig, gym: gym, kind: "lat-pulldown")
        let flow = model(rig, gym: gym, calls: calls)
        flow.skipPhoto()
        flow.chooseKind("lat-pulldown")
        flow.confirmExisting(theirs)
        calls.signedIn = user
        flow.signInFinished()
        #expect(calls.confirmed == [theirs.id] && flow.outcome == .confirmed(theirs))
    }

    @Test func aServerModelIsStoredBeforeTheListingIsCreated() throws {
        let rig = try GymTestRig.make()
        let calls = Calls()
        let gym = try mapsGym(rig)
        try cachedByOthers(rig, gym: gym, kind: "lat-pulldown")
        let flow = model(rig, gym: gym, calls: calls)
        flow.skipPhoto()
        flow.chooseKind("lat-pulldown")
        let item = CatalogueItem(item: EquipmentItem(id: UUID(), kindId: "lat-pulldown", brand: "Life Fitness",
                                                     model: "Pulldown"), gymCount: 4)
        flow.chooseCatalogueItem(item)
        flow.save()
        #expect(calls.order == ["upsert", "add"])
    }

    @Test func theServersModelsJoinTheLocalOnes() async throws {
        let rig = try GymTestRig.make()
        let calls = Calls()
        let gym = try mapsGym(rig)
        try cachedByOthers(rig, gym: gym, kind: "lat-pulldown")
        let flow = model(rig, gym: gym, calls: calls)
        flow.skipPhoto()
        flow.chooseKind("lat-pulldown")
        calls.remoteItems = [CatalogueItem(item: EquipmentItem(id: UUID(), kindId: "lat-pulldown", brand: "Hammer",
                                                               model: nil), gymCount: 9)]
        await flow.loadCatalogueItems()
        #expect(flow.known.map(\.item.brand) == ["Hammer"])
    }

    @Test func modelsThatArriveAfterTheUserMovedOnAreDropped() async throws {
        let rig = try GymTestRig.make()
        let calls = Calls()
        let gym = try mapsGym(rig)
        try cachedByOthers(rig, gym: gym, kind: "lat-pulldown")
        let flow = model(rig, gym: gym, calls: calls)
        flow.skipPhoto()
        flow.chooseKind("lat-pulldown")
        flow.back()
        calls.remoteItems = [CatalogueItem(item: EquipmentItem(id: UUID(), kindId: "lat-pulldown", brand: "Hammer",
                                                               model: nil), gymCount: 9)]
        await flow.loadCatalogueItems()
        #expect(flow.known.isEmpty)
    }
}

enum GymPhotoFixtureValue {
    static let photo = ProcessedGymPhoto(jpeg: Data("p".utf8), thumbnail: Data("t".utf8))
}
