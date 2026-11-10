import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// A workout's gym and each entry's listing: stored locally, sent only when the server has them, and never lost to a
/// pull that couldn't know about a local link.
@MainActor
@Suite struct SyncStoreWorkoutLinkTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    private var gyms: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }

    private func linked(gym: UUID?, listing: UUID?, id: UUID = UUID()) -> Workout {
        let base = sampleWorkout(id: id, at: f.clock.now)
        return base.with(entries: base.entries.map { $0.with(gymListingId: listing) }).with(gymId: gym)
    }

    private func sent(_ w: Workout) throws -> (gym: UUID?, listing: UUID?) {
        try f.workouts.save(w)
        let row = try #require(try f.store.dirtyWorkouts().first { $0.value.workout.id == w.id })
        return (row.value.workout.gymId, row.value.workout.entries.first?.gymListingId)
    }

    private func gymRecord(_ id: UUID) throws -> GymRecord {
        try #require(try f.context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.id == id })).first)
    }

    private func listingRecord(_ id: UUID) throws -> GymListingRecord {
        try #require(try f.context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first)
    }

    private func remoteRow(_ w: Workout, edit: TimeInterval = 600) -> SyncRow<WorkoutSnapshot> {
        let at = f.clock.now.addingTimeInterval(edit)
        return SyncRow(value: WorkoutSnapshot(workout: w, records: [], volumeKg: 0), clientUpdatedAt: at,
                       serverUpdatedAt: at)
    }

    // MARK: Stored locally

    @Test func aSavedWorkoutKeepsItsGymAndEachEntrysListing() throws {
        defer { f.tearDown() }
        let gym = UUID(), listing = UUID()
        let w = linked(gym: gym, listing: listing)
        try f.workouts.save(w)
        #expect(try f.workouts.workout(w.id) == w)
        let record = try #require(try f.context.fetch(FetchDescriptor<WorkoutRecord>()).first)
        record.entriesData = nil
        #expect(record.value.gymId == gym)
        #expect(record.value.entries.first?.gymListingId == listing, "the relationship read keeps it too")
    }

    @Test func withoutALinkBothAreNilAndOlderRecordsReadBackAsNil() throws {
        defer { f.tearDown() }
        let w = sampleWorkout(at: f.clock.now)
        try f.workouts.save(w)
        #expect(try f.workouts.workout(w.id)?.gymId == nil)
        #expect(try f.workouts.workout(w.id)?.entries.first?.gymListingId == nil)
        let record = try #require(try f.context.fetch(FetchDescriptor<WorkoutRecord>()).first)
        record.gymId = nil
        record.entriesData = Data(#"[{"id":"\#(UUID())","exerciseId":"bench","sets":[]}]"#.utf8)
        #expect(record.value.gymId == nil && record.value.entries.first?.gymListingId == nil)
    }

    @Test func activeWorkoutsKeepTheirLinksToo() throws {
        defer { f.tearDown() }
        let gym = UUID(), listing = UUID()
        let w = linked(gym: gym, listing: listing)
        try f.workouts.saveActive(w, pausedAt: nil)
        #expect(try f.workouts.active()?.gymId == gym)
        #expect(try f.workouts.active()?.entries.first?.gymListingId == listing)
    }

    // MARK: Pushed

    @Test func aPhoneOnlyGymAndItsListingsAreNeverSent() throws {
        defer { f.tearDown() }
        let gym = try gyms.addPrivateGym(name: "Garage", address: nil)
        let listing = try gyms.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        let result = try sent(linked(gym: gym.id, listing: listing.id))
        #expect(result.gym == nil && result.listing == nil)
        #expect(try workoutGymId() == gym.id, "the local link stays")
    }

    @Test func aMapsGymIsSentOnceItHasAServerIdAndNotBefore() throws {
        defer { f.tearDown() }
        let maps = try gyms.addMapsGym(placeId: "P1", name: "Gold", address: nil, latitude: 1, longitude: 2)
        #expect(try sent(linked(gym: maps.id, listing: nil)).gym == nil)
        let server = UUID()
        try gymRecord(maps.id).remoteId = server
        try f.context.save()
        f.clock.advance()
        #expect(try sent(linked(gym: maps.id, listing: nil)).gym == server)
    }

    @Test func aSharedListingIsSentUnderItsServerIdAndAQueuedOneIsNot() throws {
        defer { f.tearDown() }
        let maps = try gyms.addMapsGym(placeId: "P1", name: "Gold", address: nil, latitude: 1, longitude: 2)
        let listing = try gyms.addListing(NewListing(gymId: maps.id, kindId: "cable-stack"))
        let record = try listingRecord(listing.id)
        record.visibilityRaw = GymVisibility.shared.rawValue
        try f.context.save()
        #expect(try sent(linked(gym: maps.id, listing: listing.id)).listing == nil)

        let server = UUID()
        record.remoteId = server
        try f.context.save()
        f.clock.advance()
        #expect(try sent(linked(gym: maps.id, listing: listing.id)).listing == server)
    }

    @Test func aSyncedGymAndListingAreSentUnderThePhonesIdsOnceTheServerHasThem() throws {
        defer { f.tearDown() }
        let gym = try gyms.addPrivateGym(name: "Home", address: nil)
        let listing = try gyms.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        try gyms.makeSynced(listing: listing.id)
        #expect(try sent(linked(gym: gym.id, listing: listing.id)).gym == nil, "not pushed yet")

        for row in try f.store.dirtyGyms() {
            try f.store.markSynced(.gyms, id: row.value.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                                   serverUpdatedAt: f.clock.now)
        }
        for row in try f.store.dirtyGymListings() {
            try f.store.markSynced(.gymListings, id: row.value.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                                   serverUpdatedAt: f.clock.now)
        }
        f.clock.advance()
        let result = try sent(linked(gym: gym.id, listing: listing.id))
        #expect(result.gym == gym.id && result.listing == listing.id)
    }

    @Test func aLinkToARowThatIsGoneIsLeftOut() throws {
        defer { f.tearDown() }
        let result = try sent(linked(gym: UUID(), listing: UUID()))
        #expect(result.gym == nil && result.listing == nil)
    }

    // MARK: Pulled

    @Test func aPulledGymResolvesToTheLocalGymWithThatRemoteId() throws {
        defer { f.tearDown() }
        let maps = try gyms.addMapsGym(placeId: "P1", name: "Gold", address: nil, latitude: 1, longitude: 2)
        let server = UUID(), serverListing = UUID()
        try gymRecord(maps.id).remoteId = server
        let listing = try gyms.addListing(NewListing(gymId: maps.id, kindId: "cable-stack"))
        let record = try listingRecord(listing.id)
        record.visibilityRaw = GymVisibility.shared.rawValue
        record.remoteId = serverListing
        try f.context.save()

        let id = UUID()
        try f.store.applyRemote(workouts: [remoteRow(linked(gym: server, listing: serverListing, id: id))])
        let stored = try #require(try f.workouts.workout(id))
        #expect(stored.gymId == maps.id)
        #expect(stored.entries.first?.gymListingId == listing.id)
        #expect(try f.store.dirtyWorkouts().isEmpty)
    }

    @Test func aPulledLinkWithNoLocalRowStaysNil() throws {
        defer { f.tearDown() }
        let id = UUID()
        try f.store.applyRemote(workouts: [remoteRow(linked(gym: UUID(), listing: UUID(), id: id))])
        let stored = try #require(try f.workouts.workout(id))
        #expect(stored.gymId == nil && stored.entries.first?.gymListingId == nil)
    }

    @Test func aPullWithNoLinkKeepsTheLocalOne() throws {
        defer { f.tearDown() }
        let gym = try gyms.addPrivateGym(name: "Garage", address: nil)
        let listing = try gyms.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        let w = linked(gym: gym.id, listing: listing.id)
        try f.workouts.save(w)
        try f.store.markSynced(.workouts, id: w.id.uuidString, clientUpdatedAt: f.clock.now, serverUpdatedAt: f.clock.now)

        let echoed = w.with(gymId: nil).with(entries: w.entries.map { $0.with(gymListingId: nil) })
        try f.store.applyRemote(workouts: [remoteRow(echoed)])
        #expect(try f.workouts.workout(w.id)?.gymId == gym.id)
        #expect(try f.workouts.workout(w.id)?.entries.first?.gymListingId == listing.id)
    }

    // MARK: Deleted rows

    @Test func aDeletedGymLeavesTheWorkoutReadable() throws {
        defer { f.tearDown() }
        let gym = try gyms.addPrivateGym(name: "Garage", address: nil)
        let listing = try gyms.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        let w = linked(gym: gym.id, listing: listing.id)
        try f.workouts.save(w)
        _ = try gyms.deleteGym(gym.id)

        let read = try #require(try f.workouts.workout(w.id))
        #expect(read.entries.map(\.exerciseId) == ["bench"] && read.entries.first?.sets.count == 2)
        #expect(try f.workouts.recent(limit: 5).count == 1)
        let result = try sent(read.with(gymId: read.gymId))
        #expect(result.gym == nil && result.listing == nil)
    }

    private func workoutGymId() throws -> UUID? {
        try f.context.fetch(FetchDescriptor<WorkoutRecord>()).first?.gymId
    }
}
