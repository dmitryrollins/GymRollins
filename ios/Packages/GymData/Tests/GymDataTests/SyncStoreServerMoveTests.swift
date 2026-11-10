import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// The server move (spec section 4): a launch against another API hands the data to the next account that signs in and
/// marks every synced record unsynced, deleting nothing but Claude's pending proposals.
@MainActor
@Suite struct SyncStoreServerMoveTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    private let old = "http://127.0.0.1:55421"
    private let new = "http://127.0.0.1:8787"

    private var gyms: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }
    private var proposals: ProposalRepository {
        ProposalRepository(context: f.context, now: { [clock = f.clock] in clock.now })
    }

    /// What a finished round on the old server leaves: every dirty row acknowledged with a server version.
    private func syncEverything() throws {
        let s = f.store
        let at = f.clock.now
        if let row = try s.dirtyProfile() {
            try s.markSynced(.profile, id: SyncStore.profileSyncID, clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
        for row in try s.dirtyCustomExercises() {
            try s.markSynced(.customExercises, id: row.value.id, clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
        for row in try s.dirtyExercisePreferences() {
            try s.markSynced(.exercisePreferences, id: row.value.exerciseId, clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
        for row in try s.dirtyRoutines() {
            try s.markSynced(.routines, id: row.value.routine.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
        for row in try s.dirtyWeekdays() {
            try s.markSynced(.weekSchedule, id: String(row.value.weekday), clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
        for row in try s.dirtyMuscleTargets() {
            try s.markSynced(.muscleTargets, id: row.value.group.rawValue, clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
        for row in try s.dirtyGyms() {
            try s.markSynced(.gyms, id: row.value.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
        for row in try s.dirtyGymListings() {
            try s.markSynced(.gymListings, id: row.value.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
        for row in try s.dirtyBodyweight() {
            try s.markSynced(.bodyweight, id: row.value.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
        for row in try s.dirtyWorkouts() {
            try s.markSynced(.workouts, id: row.value.workout.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
    }

    private func dirtyCount() throws -> Int {
        let s = f.store
        var count = try s.dirtyProfile() == nil ? 0 : 1
        count += try s.dirtyCustomExercises().count
        count += try s.dirtyExercisePreferences().count
        count += try s.dirtyRoutines().count
        count += try s.dirtyWeekdays().count
        count += try s.dirtyMuscleTargets().count
        count += try s.dirtyGyms().count
        count += try s.dirtyGymListings().count
        count += try s.dirtyBodyweight().count
        count += try s.dirtyWorkouts().count
        return count
    }

    /// One of everything that syncs, synced to the old server by `owner`, with every cursor set.
    @discardableResult
    private func syncedAccount(owner: UUID = UUID()) throws -> Workout {
        try f.profiles.save(Profile(unit: .kg))
        let routine = sampleRoutine()
        try f.routines.upsert(routine)
        try f.routines.setSchedule(weekday: 1, routineId: routine.id)
        _ = try f.custom.create(name: "Sled", bodyPart: "legs", equipment: "sled", target: "quads", mode: .reps,
                                bilateral: false)
        try ExercisePreferenceRepository(context: f.context, now: { [clock = f.clock] in clock.now })
            .set(.more, for: "bench")
        try MuscleTargetRepository(context: f.context, now: { [clock = f.clock] in clock.now })
            .set(.chest, SetTargetRange(min: 12, max: 18))
        try f.body.add(BodyweightEntry(date: f.clock.now, weightKg: 81))
        let workout = sampleWorkout(at: f.clock.now)
        try f.workouts.save(workout)
        try syncEverything()
        f.store.ownerUserId = owner
        for entity in SyncEntity.allCases { f.store.setCursor(f.clock.now, for: entity) }
        f.store.syncedServer = old
        return workout
    }

    private func gymRecord(_ id: UUID) throws -> GymRecord {
        try #require(try f.context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.id == id })).first)
    }

    private func listingRecord(_ id: UUID) throws -> GymListingRecord {
        try #require(try f.context.fetch(
            FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first)
    }

    @Test func aFirstLaunchWithNothingFromAServerOnlyRemembersIt() throws {
        defer { f.tearDown() }
        try f.routines.upsert(sampleRoutine()) // made before ever signing in: dirty, no owner, no server version
        #expect(try !f.store.moveToServer(new))
        #expect(f.store.syncedServer == new)
        #expect(try f.store.dirtyRoutines().count == 1)
    }

    @Test func theSameServerChangesNothing() throws {
        defer { f.tearDown() }
        let owner = UUID()
        try syncedAccount(owner: owner)
        f.store.syncedServer = new
        #expect(try !f.store.moveToServer(new))
        #expect(f.store.ownerUserId == owner)
        #expect(f.store.cursor(for: .workouts) != nil)
        #expect(try dirtyCount() == 0)
    }

    @Test func anotherServerHandsTheDataToTheNextAccountAndDeletesNothing() throws {
        defer { f.tearDown() }
        let workout = try syncedAccount()
        let edited = try #require(try f.context.fetch(FetchDescriptor<WorkoutRecord>()).first?.updatedAt)
        f.store.recordSyncFailure(SyncFailure(entity: .routines, id: UUID().uuidString, clientUpdatedAt: f.clock.now,
                                              message: "refused"))
        #expect(try dirtyCount() == 0)

        #expect(try f.store.moveToServer(new))

        #expect(f.store.ownerUserId == nil)
        #expect(SyncEntity.allCases.allSatisfy { f.store.cursor(for: $0) == nil })
        #expect(f.store.syncFailures().isEmpty)
        #expect(f.store.syncedServer == new)
        #expect(try dirtyCount() == 8,
                "profile, custom exercise, preference, routine, weekday, target, weigh-in, workout")
        let row = try #require(try f.store.dirtyWorkouts().first)
        #expect(row.value.workout.id == workout.id)
        #expect(row.serverUpdatedAt == nil, "it goes up with no base version, as a new workout")
        #expect(row.clientUpdatedAt == edited, "the edit time stays, so last-write-wins compares real edits")
        #expect(try f.workouts.workout(workout.id) != nil)
    }

    @Test func noRecordedServerCountsAsAnother() throws {
        defer { f.tearDown() }
        try syncedAccount()
        f.store.syncedServer = nil // the owner's phone today: synced to the old server, which recorded nothing
        #expect(try f.store.moveToServer(new))
        #expect(f.store.ownerUserId == nil)
    }

    @Test func syncedGymsAndListingsMoveAndThisPhoneOnlyOnesStayPut() throws {
        defer { f.tearDown() }
        let synced = try gyms.addPrivateGym(name: "Home", address: nil)
        let listing = try gyms.addListing(NewListing(gymId: synced.id, kindId: "cable-stack", photoFile: "p.jpg"))
        try gyms.makeSynced(listing: listing.id)
        let phoneOnly = try gyms.addPrivateGym(name: "Garage", address: nil)
        let kept = try gyms.addListing(NewListing(gymId: phoneOnly.id, kindId: "cable-stack"))
        try syncEverything()
        try f.store.setRemotePhotoPath(listingId: listing.id, path: "old-server.jpg")
        f.store.ownerUserId = UUID()
        let before = try listingRecord(kept.id)
        let keptState = (before.dirty, before.updatedAt, before.visibilityRaw)
        let garage = try gymRecord(phoneOnly.id)
        let garageState = (garage.dirty, garage.serverUpdatedAt, garage.updatedAt)

        #expect(try f.store.moveToServer(new))

        #expect(try f.store.dirtyGyms().map(\.value.id) == [synced.id])
        let moved = try #require(try f.store.dirtyGymListings().first)
        #expect(moved.value.id == listing.id)
        #expect(moved.serverUpdatedAt == nil)
        #expect(moved.value.remotePhotoPath == nil, "the picture uploads again to the new server")
        #expect(moved.value.photoFile == "p.jpg")
        let after = try listingRecord(kept.id)
        #expect(after.dirty == keptState.0 && after.updatedAt == keptState.1 && after.visibilityRaw == keptState.2)
        let garageAfter = try gymRecord(phoneOnly.id)
        #expect(garageAfter.dirty == garageState.0, "the Garage keeps its dirty flag")
        #expect(garageAfter.serverUpdatedAt == garageState.1, "and its server version")
        #expect(garageAfter.updatedAt == garageState.2, "and its edit time")
    }

    @Test func aMoveCutShortAfterTheSaveRunsAgainToTheSameEnd() throws {
        defer { f.tearDown() }
        let owner = UUID()
        let workout = try syncedAccount(owner: owner)
        let edited = try #require(try f.context.fetch(FetchDescriptor<WorkoutRecord>()).first?.updatedAt)
        #expect(try f.store.moveToServer(new))

        // The app died after the store was saved, before the owner and cursors were forgotten: the old server's
        // leftovers are back and the new server was never recorded.
        f.store.ownerUserId = owner
        f.store.setCursor(f.clock.now, for: .routines)
        f.store.syncedServer = old

        #expect(try f.store.moveToServer(new))

        #expect(f.store.ownerUserId == nil)
        #expect(SyncEntity.allCases.allSatisfy { f.store.cursor(for: $0) == nil })
        #expect(f.store.syncedServer == new)
        #expect(try dirtyCount() == 8)
        let row = try #require(try f.store.dirtyWorkouts().first)
        #expect(row.value.workout.id == workout.id && row.serverUpdatedAt == nil && row.clientUpdatedAt == edited)
        #expect(try !f.store.moveToServer(new), "and then it is done")
    }

    @Test func pendingProposalsGoAndResolutionsCountAsSent() throws {
        defer { f.tearDown() }
        let pending = Proposal(id: UUID(), createdAt: f.clock.now, summary: "Heavier bench", changes: [
            PlanChange(id: "c1", type: .weight, routineId: UUID().uuidString.lowercased(), exerciseId: "bench",
                       weightKg: 65),
        ])
        let dismissed = Proposal(id: UUID(), createdAt: f.clock.now, summary: "Fewer sets", changes: [
            PlanChange(id: "c1", type: .sets, routineId: UUID().uuidString.lowercased(), exerciseId: "bench", sets: 2),
        ])
        try f.store.applyRemote(proposals: [pending, dismissed])
        try proposals.dismiss(dismissed.id) // resolved here, not yet sent
        f.store.ownerUserId = UUID()

        #expect(try f.store.moveToServer(new))

        #expect(try f.store.pendingProposalIds().isEmpty)
        #expect(try f.store.dirtyProposals().isEmpty, "the new server never had it to resolve")
        #expect(try proposals.proposal(dismissed.id)?.status == .dismissed)
    }

    @Test func aWorkoutAtAMovedGymGoesUpWithoutItsLinkAndKeepsItHere() throws {
        defer { f.tearDown() }
        let gym = try gyms.addPrivateGym(name: "Home", address: nil)
        try gyms.makeSynced(gym: gym.id)
        let workout = sampleWorkout(at: f.clock.now).with(gymId: gym.id)
        try f.workouts.save(workout)
        try syncEverything()
        f.store.ownerUserId = UUID()

        try f.store.moveToServer(new)

        let sent = try #require(try f.store.dirtyWorkouts().first)
        #expect(sent.value.workout.gymId == nil, "the new server hasn't got the gym yet")
        try f.store.markSynced(.workouts, id: workout.id.uuidString, clientUpdatedAt: sent.clientUpdatedAt,
                               serverUpdatedAt: f.clock.now)
        let echoed = SyncRow(value: WorkoutSnapshot(workout: workout.with(gymId: nil), records: [], volumeKg: 0),
                             clientUpdatedAt: sent.clientUpdatedAt, serverUpdatedAt: f.clock.now)
        try f.store.applyRemote(workouts: [echoed])
        #expect(try f.workouts.workout(workout.id)?.gymId == gym.id, "the server's null doesn't replace the local link")
    }

    @Test func theMoveRunsOnce() throws {
        defer { f.tearDown() }
        try syncedAccount()
        #expect(try f.store.moveToServer(new))
        try syncEverything()
        f.store.ownerUserId = UUID() // the account that signed in afterwards
        #expect(try !f.store.moveToServer(new))
        #expect(f.store.ownerUserId != nil)
        #expect(try dirtyCount() == 0)
    }
}
