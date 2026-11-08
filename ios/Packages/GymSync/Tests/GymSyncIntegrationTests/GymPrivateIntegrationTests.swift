import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymSync

private final class MemoryPhotoFiles: GymPhotoFiles, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]
    init(_ files: [String: Data] = [:]) { self.files = files }
    var stored: [String: Data] { lock.withLock { files } }
    func data(file: String) -> Data? { lock.withLock { files[file] } }
    func save(_ jpeg: Data, file: String) throws { lock.withLock { files[file] = jpeg } }
    func delete(file: String) throws { lock.withLock { files[file] = nil } }
}

/// Private gyms, listings and photos against the local stack: a second device of the same user gets them; another
/// user and a signed-out client get nothing.
@MainActor
@Suite(.enabled(if: apiConfigured, "Set API_URL (scripts/test-sync-integration.sh) to run against a local Worker"))
struct GymPrivateIntegrationTests {
    @MainActor private struct Phone {
        let container: ModelContainer
        let store: SyncStore
        let engine: SyncEngine
        let photos: MemoryPhotoFiles
        let repo: GymRepository

        init(_ account: Account, clock: DeviceClock, photos: MemoryPhotoFiles = MemoryPhotoFiles()) throws {
            container = try GymStore.container(inMemory: true)
            let defaults = UserDefaults(suiteName: "gym-it-\(UUID())")!
            store = SyncStore(context: container.mainContext, defaults: defaults, now: { clock.now })
            engine = SyncEngine(store: store, transport: account.transport, photos: photos, now: { clock.now })
            self.photos = photos
            repo = GymRepository(context: container.mainContext, now: { clock.now })
        }
    }

    private func anonTransport() throws -> ApiSyncTransport { try GymIntegration.signedOutTransport() }

    @Test func aPrivateGymListingAndPhotoReachAnotherDeviceAndNoOneElse() async throws {
        let owner = try await Account.signUp()
        let stranger = try await Account.signUp()
        let clock = DeviceClock("2026-10-30T12:00:00.000000Z")
        let jpeg = GymIntegration.jpeg
        let first = try Phone(owner, clock: clock, photos: MemoryPhotoFiles(["mine.jpg": jpeg]))

        let gym = try first.repo.addPrivateGym(name: "Garage", address: "1 Home St")
        let listing = try first.repo.addListing(NewListing(gymId: gym.id, kindId: "cable-station", brand: "Hammer",
                                                           loads: .stack(maxKg: 90, stepKg: 5), notes: "garage",
                                                           photoFile: "mine.jpg"))
        try first.repo.makeSynced(listing: listing.id)
        await first.engine.sync()
        #expect(first.engine.status == .idle)
        #expect(try first.store.dirtyGyms().isEmpty && first.store.dirtyGymListings().isEmpty,
                "\(first.store.syncFailures().map(\.message)) \(first.engine.status)")
        let path = try #require(try first.container.mainContext.fetch(FetchDescriptor<GymListingRecord>()).first?.remotePhotoPath)

        let other = try Phone(stranger, clock: clock)
        await other.engine.sync()
        #expect(try other.repo.gyms().isEmpty)

        let second = try Phone(try await owner.onAnotherDevice(), clock: clock)
        await second.engine.sync()
        #expect(second.engine.status == .idle)

        // The owner has now downloaded the picture; no client may be served it from a cache afterwards.
        let anon = try anonTransport()
        // Refused outright or empty: either way a signed-out client reads nothing.
        #expect((try? await anon.pullGyms(since: nil))?.isEmpty ?? true)
        #expect((try? await anon.pullGymListings(since: nil))?.isEmpty ?? true)
        await #expect(throws: (any Error).self) { _ = try await anon.downloadPrivatePhoto(path: path) }
        await #expect(throws: (any Error).self) { _ = try await stranger.transport.downloadPrivatePhoto(path: path) }

        let copy = try #require(try second.repo.listings(gymId: gym.id).first)
        #expect(copy.id == listing.id && copy.item.brand == "Hammer" && copy.notes == "garage")
        #expect(copy.loads == .stack(maxKg: 90, stepKg: 5))
        let file = try #require(copy.photoFile)
        #expect(second.photos.stored[file] == jpeg)

        clock.advance(60)
        _ = try first.repo.removeListing(listing.id)
        await first.engine.sync()
        #expect(try first.container.mainContext.fetchCount(FetchDescriptor<GymListingRecord>()) == 0)
        clock.advance(60)
        await second.engine.sync()
        #expect(try second.repo.listings(gymId: gym.id).isEmpty)
        await #expect(throws: (any Error).self) { _ = try await owner.transport.downloadPrivatePhoto(path: path) }

        try await owner.deleteAccount()
        try await stranger.deleteAccount()
    }

    @Test func aWorkoutKeepsItsSyncedGymAndListingAcrossDevicesButNeverALocalOne() async throws {
        let owner = try await Account.signUp()
        let clock = DeviceClock("2026-10-30T12:00:00.000000Z")
        let first = try Phone(owner, clock: clock)
        let workouts = WorkoutRepository(context: first.container.mainContext, now: { clock.now })

        let gym = try first.repo.addPrivateGym(name: "Garage", address: nil)
        let listing = try first.repo.addListing(NewListing(gymId: gym.id, kindId: "cable-station",
                                                           loads: .stack(maxKg: 90, stepKg: 5)))
        try first.repo.makeSynced(listing: listing.id)
        let local = try first.repo.addPrivateGym(name: "Phone only", address: nil)
        let localListing = try first.repo.addListing(NewListing(gymId: local.id, kindId: "cable-station"))
        await first.engine.sync()

        func workout(gym: UUID, listing: UUID) -> Workout {
            Workout(startedAt: clock.now, endedAt: clock.now.addingTimeInterval(600), name: "Pull", entries: [
                WorkoutEntry(exerciseId: "bench", sets: [WorkoutSet(weightKg: 50, reps: 8, done: true)],
                             gymListingId: listing)], gymId: gym)
        }
        let linked = workout(gym: gym.id, listing: listing.id)
        let phoneOnly = workout(gym: local.id, listing: localListing.id)
        try workouts.save(linked)
        try workouts.save(phoneOnly)
        await first.engine.sync()
        #expect(first.engine.status == .idle, "\(first.store.syncFailures().map(\.message))")
        #expect(try workouts.workout(phoneOnly.id)?.gymId == local.id, "a pull never clears a local link")

        let second = try Phone(try await owner.onAnotherDevice(), clock: clock)
        await second.engine.sync()
        let other = WorkoutRepository(context: second.container.mainContext, now: { clock.now })
        #expect(try other.workout(linked.id)?.gymId == gym.id)
        #expect(try other.workout(linked.id)?.entries.first?.gymListingId == listing.id)
        #expect(try other.workout(phoneOnly.id)?.gymId == nil)

        try await owner.deleteAccount()
    }
    // MARK: Two accounts on one phone

    @Test func theNextAccountOnThePhoneGetsItsOwnGymIdsAndBothAccountsKeepTheirRows() async throws {
        let first = try await Account.signUp()
        let second = try await Account.signUp()
        let clock = DeviceClock("2026-10-30T12:00:00.000000Z")
        let phone = try Phone(first, clock: clock)
        phone.store.ownerUserId = first.userId
        let gym = try phone.repo.addPrivateGym(name: "Garage", address: nil)
        let listing = try phone.repo.addListing(NewListing(gymId: gym.id, kindId: "cable-station"))
        try phone.repo.makeSynced(listing: listing.id)
        await phone.engine.sync()
        #expect(try phone.store.dirtyGyms().isEmpty)
        // Edited while offline, so the listing survives the sign-out as an unpushed change.
        clock.advance(60)
        _ = try phone.repo.updateListing(listing.id, loads: .none, quantity: 2, notes: "edited offline")
        _ = try phone.store.resetAccountData()

        // The second account signs in on the same phone, syncs the gym and a workout.
        phone.store.ownerUserId = second.userId
        let moves = try phone.store.settleDemotedRows(for: second.userId)
        let newGym = try #require(moves[gym.id])
        let workouts = WorkoutRepository(context: phone.container.mainContext, now: { clock.now })
        try workouts.save(finishedWorkout(name: "Push", at: clock.now))
        try phone.repo.makeSynced(gym: newGym)
        let engine = SyncEngine(store: phone.store, transport: second.transport, photos: phone.photos,
                                now: { clock.now })
        await engine.sync()
        #expect(engine.status == .idle, "\(phone.store.syncFailures().map(\.message))")
        #expect(phone.store.syncFailures().isEmpty)

        #expect(try await second.transport.pullGyms(since: nil).map(\.id) == [newGym])
        #expect(try await second.transport.pullWorkouts(since: nil).count == 1)
        let untouched = try await first.transport.pullGyms(since: nil)
        #expect(untouched.map(\.id) == [gym.id] && untouched.first?.name == "Garage")
        let theirs = try await first.transport.pullGymListings(since: nil)
        #expect(theirs.map(\.id) == [listing.id] && theirs.first?.notes == nil)

        try await first.deleteAccount()
        try await second.deleteAccount()
    }

    @Test func aGymAnotherAccountHoldsIsRefusedForThatRowAndTheRoundGoesOn() async throws {
        let first = try await Account.signUp()
        let second = try await Account.signUp()
        let clock = DeviceClock("2026-10-30T12:00:00.000000Z")
        let phoneA = try Phone(first, clock: clock)
        let gym = try phoneA.repo.addPrivateGym(name: "Garage", address: nil)
        try phoneA.repo.makeSynced(gym: gym.id)
        await phoneA.engine.sync()

        // A phone whose row carries the first account's id (what an old demoted row used to look like).
        let phoneB = try Phone(second, clock: clock)
        let clash = GymRecord(id: gym.id, name: "Mine now", address: nil, now: clock.now)
        clash.visibilityRaw = GymVisibility.synced.rawValue
        clash.dirty = true
        phoneB.container.mainContext.insert(clash)
        try phoneB.container.mainContext.save()
        let workouts = WorkoutRepository(context: phoneB.container.mainContext, now: { clock.now })
        try workouts.save(finishedWorkout(name: "Push", at: clock.now))
        await phoneB.engine.sync()

        #expect(try await second.transport.pullWorkouts(since: nil).count == 1, "the workout is not held back")
        #expect(phoneB.store.syncFailures().map(\.entity) == [.gyms])
        let untouched = try await first.transport.pullGyms(since: nil)
        #expect(untouched.first?.name == "Garage")

        try await first.deleteAccount()
        try await second.deleteAccount()
    }

    /// Account deletion that fails after the photos went: no row names a deleted object, the phone uploads its pictures
    /// again at the next sync, and a retry deletes the account.
    @Test func aDeletionRefusedAfterThePhotosWentLeavesNoRowNamingThemAndTheNextSyncUploadsAgain() async throws {
        let user = try await Account.signUp()
        let clock = DeviceClock("2026-10-30T12:00:00.000000Z")
        let jpeg = GymIntegration.jpeg
        let phone = try Phone(user, clock: clock, photos: MemoryPhotoFiles(["mine.jpg": jpeg]))
        let catalog = user.catalog

        let gym = try phone.repo.addPrivateGym(name: "Garage", address: nil)
        let listing = try phone.repo.addListing(NewListing(gymId: gym.id, kindId: "cable-station",
                                                           loads: .stack(maxKg: 90, stepKg: 5), photoFile: "mine.jpg"))
        try phone.repo.makeSynced(listing: listing.id)
        await phone.engine.sync()
        let record = try #require(try phone.container.mainContext.fetch(FetchDescriptor<GymListingRecord>()).first)
        let oldPath = try #require(record.remotePhotoPath)

        let place = "it-\(UUID().uuidString.lowercased())"
        let sharedGym = try await catalog.findOrCreateGym(mapsPlaceId: place, name: "Iron Works", address: nil,
                                                          latitude: 52.5, longitude: 13.4)
        let sharedName = "\(UUID().uuidString.lowercased()).jpg"
        _ = try await catalog.uploadSharedPhoto(jpeg, name: sharedName)
        let sharedId = UUID()
        _ = try await catalog.share(ShareRequest(
            listingId: sharedId, gymId: sharedGym, kindId: "leg-press", brand: nil, model: nil,
            loads: .stack(maxKg: 90, stepKg: 5), quantity: 1, notes: nil, photoPath: sharedName, forceNew: false))

        // The server stamps the detach with its real clock, and the phone's edit has to be newer than that, as a real
        // phone's is a moment later; the fixed clock the other tests use is a day behind.
        clock.now = Date().addingTimeInterval(60)
        struct Refused: Error {}
        nonisolated(unsafe) let store = phone.store
        let steps = AccountPhotoSteps(
            detach: { try await catalog.detachAllPhotos(); try await MainActor.run { try store.forgetRemotePhotos() } },
            remove: { try await catalog.deleteAllPhotos() })
        // The server step fails after the photos are gone, as a lost connection or a refusal would.
        await #expect(throws: AuthFailure.self) {
            try await user.auth.deleteAccount(photos: steps) { throw Refused() }
        }

        let rows = try await user.transport.pullGymListings(since: nil)
        #expect(rows.count == 1 && rows.first.map { $0.photoPath } == .some(nil), "the server's row holds no path")
        let shared = try #require(try await catalog.publicListings(gymId: sharedGym).listings.first { $0.id == sharedId })
        #expect(shared.photoPath == nil, "the shared listing stays, without its photo")
        #expect(record.remotePhotoPath == nil && record.photoFile == "mine.jpg" && record.dirty)

        clock.advance(60)
        await phone.engine.sync()
        let newPath = try #require(record.remotePhotoPath)
        #expect(newPath != oldPath, "the picture went up again under a new name")
        #expect(try await user.transport.pullGymListings(since: nil).first?.photoPath == newPath)
        #expect(try await user.transport.downloadPrivatePhoto(path: newPath) == jpeg)

        try await user.deleteAccount() // the retry
    }

    // MARK: After a server move

    /// Plan 27 left this to plan 28: a phone moved from another server sends its gyms and listings in the same round
    /// as the workouts that link them, gyms first, so the links reach the new server.
    @Test func aPhoneMovedFromAnotherServerSendsItsGymsBeforeTheWorkoutsThatLinkThem() async throws {
        let clock = DeviceClock("2026-10-30T12:00:00.000000Z")
        let earlier = try await Account.signUp()
        let phone = try Phone(earlier, clock: clock)
        let workouts = WorkoutRepository(context: phone.container.mainContext, now: { clock.now })
        let gym = try phone.repo.addPrivateGym(name: "Garage", address: nil)
        let listing = try phone.repo.addListing(NewListing(gymId: gym.id, kindId: "cable-station",
                                                           loads: .stack(maxKg: 90, stepKg: 5)))
        try phone.repo.makeSynced(listing: listing.id)
        let linked = Workout(startedAt: clock.now, endedAt: clock.now.addingTimeInterval(600), name: "Pull", entries: [
            WorkoutEntry(exerciseId: "bench", sets: [WorkoutSet(weightKg: 50, reps: 8, done: true)],
                         gymListingId: listing.id)], gymId: gym.id)
        try workouts.save(linked)
        await phone.engine.sync()
        #expect(phone.engine.status == .idle, "\(phone.store.syncFailures().map(\.message))")

        // The "old server" here is this Worker as another account; deleting it frees the ids, as a new server has them.
        #expect(try phone.store.moveToServer("http://moved.invalid"))
        try await earlier.deleteAccount()
        let next = try await Account.signUp()
        phone.store.ownerUserId = next.userId
        let engine = SyncEngine(store: phone.store, transport: next.transport, photos: phone.photos, now: { clock.now })
        await engine.sync()

        #expect(engine.status == .idle, "\(phone.store.syncFailures().map(\.message))")
        let pulled = try #require(try await next.transport.pullWorkouts(since: nil).first { $0.id == linked.id })
        #expect(pulled.gymId == gym.id)
        #expect(pulled.entries.first?.gymEquipmentId == listing.id)
        try await next.deleteAccount()
    }
}
