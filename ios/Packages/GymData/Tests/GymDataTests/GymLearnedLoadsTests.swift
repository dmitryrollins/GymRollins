import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Weights a finished workout showed for a fixed set are kept on the listing, marked "from workouts", until the user
/// saves the loads themselves (owner, 2026-11-22).
@MainActor
@Suite struct GymLearnedLoadsTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    private var repo: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }

    private func listing(_ loads: ListingLoads = .none, fromWorkouts: Bool = false, gymName: String = "Garage")
        throws -> GymListing {
        let gym = try repo.addPrivateGym(name: gymName, address: nil)
        return try repo.addListing(NewListing(gymId: gym.id, kindId: "dumbbells", loads: loads,
                                              loadsFromWorkouts: fromWorkouts))
    }

    private func record(_ id: UUID) throws -> GymListingRecord {
        try #require(try f.context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first)
    }

    @Test func aNewListingCarriesTheFlagAndItDefaultsToOff() throws {
        defer { f.tearDown() }
        #expect(try listing().loadsFromWorkouts == false)
        let learned = try listing(.fixed(kg: [10]), fromWorkouts: true, gymName: "Other")
        #expect(learned.loadsFromWorkouts)
        #expect(try repo.listing(learned.id)?.loadsFromWorkouts == true)
    }

    @Test func aListingWithNoWeightsIsFilledAndMarked() throws {
        defer { f.tearDown() }
        let bare = try listing()
        #expect(try repo.learnWeights([12, 8], forListing: bare.id))
        let after = try #require(try repo.listing(bare.id))
        #expect(after.loads == .fixed(kg: [8, 12]) && after.loadsFromWorkouts)
    }

    /// Older builds learned dumbbells with an empty set of weights too.
    @Test func anEmptyFixedSetCountsAsLearned() throws {
        defer { f.tearDown() }
        let bare = try listing()
        try record(bare.id).loadsData = JSONEncoder().encode(ListingLoads.fixed(kg: [])) // a screen can't save this
        #expect(try repo.learnWeights([12], forListing: bare.id))
        #expect(try repo.listing(bare.id)?.loadsFromWorkouts == true)
    }

    @Test func aLearnedListingGainsNewWeightsOnly() throws {
        defer { f.tearDown() }
        let learned = try listing(.fixed(kg: [10, 12]), fromWorkouts: true)
        #expect(try repo.learnWeights([12.1, 14], forListing: learned.id))
        #expect(try repo.listing(learned.id)?.loads == .fixed(kg: [10, 12, 14]))
        #expect(try repo.learnWeights([10, 14], forListing: learned.id) == false, "nothing new, nothing saved")
    }

    @Test func aListingTheUserMadeIsNeverChanged() throws {
        defer { f.tearDown() }
        let mine = try listing(.fixed(kg: [10, 20]))
        #expect(try repo.learnWeights([12, 30], forListing: mine.id) == false)
        let after = try #require(try repo.listing(mine.id))
        #expect(after.loads == .fixed(kg: [10, 20]) && !after.loadsFromWorkouts)
    }

    @Test func savingTheLoadsMakesTheListThePersons() throws {
        defer { f.tearDown() }
        let learned = try listing(.fixed(kg: [10, 12]), fromWorkouts: true)
        let saved = try repo.updateListing(learned.id, loads: .fixed(kg: [10, 12]), quantity: 1, notes: nil)
        #expect(saved.loadsFromWorkouts == false)
        #expect(try repo.learnWeights([14], forListing: learned.id) == false)
        #expect(try repo.listing(learned.id)?.loads == .fixed(kg: [10, 12]))
    }

    @Test func aSyncedLearnedListingGrowsAndWaitsToBePushed() throws {
        defer { f.tearDown() }
        let learned = try listing(.fixed(kg: [10]), fromWorkouts: true)
        try repo.makeSynced(listing: learned.id)
        try record(learned.id).dirty = false
        f.clock.advance()
        #expect(try repo.learnWeights([12], forListing: learned.id))
        #expect(try record(learned.id).dirty)
    }

    @Test func weightsOutOfRangeOrAnUnknownListingChangeNothing() throws {
        defer { f.tearDown() }
        let bare = try listing()
        #expect(try repo.learnWeights([0, -3, 900], forListing: bare.id) == false)
        #expect(try repo.listing(bare.id)?.loads == ListingLoads.none)
        #expect(try repo.learnWeights([12], forListing: UUID()) == false)
    }

    @Test func aSyncedListingWithNoWeightsIsFilledAndMarkedButASharedOneIsNot() throws {
        defer { f.tearDown() }
        let synced = try listing()
        try repo.makeSynced(listing: synced.id)
        #expect(try repo.learnWeights([12], forListing: synced.id), "another phone's listing learns its own")
        let after = try #require(try repo.listing(synced.id))
        #expect(after.loads == .fixed(kg: [12]) && after.loadsFromWorkouts)
        let shared = try listing(gymName: "Other")
        try record(shared.id).visibilityRaw = GymVisibility.shared.rawValue
        #expect(try repo.learnWeights([12], forListing: shared.id) == false)
    }

    /// The screen saves the list it shows, so any save makes the list the user's.
    @Test func aSaveThatChangesOnlyTheQuantityClearsTheFlag() throws {
        defer { f.tearDown() }
        let learned = try listing(.fixed(kg: [10, 12]), fromWorkouts: true)
        let saved = try repo.updateListing(learned.id, loads: .fixed(kg: [10, 12]), quantity: 2, notes: nil)
        #expect(saved.loadsFromWorkouts == false && saved.quantity == 2)
    }

    // MARK: Pulled rows

    private func pull(_ id: UUID, gym: UUID, loads: ListingLoads?) throws {
        let at = f.clock.now.addingTimeInterval(600)
        let value = SyncedListing(id: id, gymId: gym, kindId: "dumbbells", brand: nil, model: nil, loads: loads,
                                  quantity: 1, notes: nil, photoFile: nil, remotePhotoPath: nil)
        try f.store.applyRemote(gymListings: [SyncRow(value: value, clientUpdatedAt: at, deletedAt: nil,
                                                      serverUpdatedAt: at)])
    }

    private func syncedListing(_ loads: ListingLoads, fromWorkouts: Bool) throws -> GymListing {
        let learned = try listing(loads, fromWorkouts: fromWorkouts)
        try repo.makeSynced(listing: learned.id)
        return learned
    }

    @Test func aPulledRowWithNoWeightsKeepsAFlaggedRow() throws {
        defer { f.tearDown() }
        let learned = try syncedListing(.fixed(kg: [10, 12]), fromWorkouts: true)
        for echo in [ListingLoads.none, .fixed(kg: [])] {
            try pull(learned.id, gym: learned.gymId, loads: echo)
            let after = try #require(try repo.listing(learned.id))
            #expect(after.loads == .fixed(kg: [10, 12]) && after.loadsFromWorkouts)
        }
    }

    @Test func aPulledWeightListReplacesAFlaggedRowAndClearsTheFlag() throws {
        defer { f.tearDown() }
        let learned = try syncedListing(.fixed(kg: [10, 12]), fromWorkouts: true)
        try pull(learned.id, gym: learned.gymId, loads: .fixed(kg: [10, 20, 30]))
        let after = try #require(try repo.listing(learned.id))
        #expect(after.loads == .fixed(kg: [10, 20, 30]) && !after.loadsFromWorkouts)
    }

    @Test func aPulledRowIsTakenAsBeforeWhenTheLocalRowIsNotFlagged() throws {
        defer { f.tearDown() }
        let mine = try syncedListing(.fixed(kg: [10, 12]), fromWorkouts: false)
        try pull(mine.id, gym: mine.gymId, loads: .none)
        #expect(try repo.listing(mine.id)?.loads == ListingLoads.none)
        try pull(mine.id, gym: mine.gymId, loads: .fixed(kg: [5, 6]))
        let after = try #require(try repo.listing(mine.id))
        #expect(after.loads == .fixed(kg: [5, 6]) && !after.loadsFromWorkouts)
    }

    /// Loads this version can't read: the row becomes unsupported as always, and what was learned no longer matters.
    @Test func aPulledUnsupportedRowClearsTheFlag() throws {
        defer { f.tearDown() }
        let learned = try syncedListing(.fixed(kg: [10]), fromWorkouts: true)
        try pull(learned.id, gym: learned.gymId, loads: nil)
        let row = try record(learned.id)
        #expect(row.statusRaw == ListingStatus.unsupported.rawValue && !row.loadsFromWorkouts)
    }

    @Test func aFlaggedSyncedRowIsPushedWithoutWeightsAndKeepsThem() throws {
        defer { f.tearDown() }
        let learned = try syncedListing(.fixed(kg: [10, 12]), fromWorkouts: true)
        let pushed = try #require(try f.store.dirtyGymListings().first { $0.value.id == learned.id })
        #expect(pushed.value.loads == ListingLoads.none)
        let after = try #require(try repo.listing(learned.id))
        #expect(after.loads == .fixed(kg: [10, 12]) && after.loadsFromWorkouts)
        let mine = try syncedListing(.fixed(kg: [10, 12]), fromWorkouts: false)
        let pushedMine = try #require(try f.store.dirtyGymListings().first { $0.value.id == mine.id })
        #expect(pushedMine.value.loads == .fixed(kg: [10, 12]))
    }
}
