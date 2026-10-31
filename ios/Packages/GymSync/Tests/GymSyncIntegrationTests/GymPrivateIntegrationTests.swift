import Foundation
import GymCore
import GymData
import Supabase
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
@Suite(.enabled(if: supabaseConfigured, "Set SUPABASE_URL and SUPABASE_ANON_KEY to run against local Supabase"))
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

    private func anonTransport() throws -> SupabaseTransport {
        SupabaseTransport(client: try IntegrationEnv.config().makeClient(storage: InMemoryAuthStorage()))
    }

    @Test func aPrivateGymListingAndPhotoReachAnotherDeviceAndNoOneElse() async throws {
        let owner = try await Account.signUp()
        let stranger = try await Account.signUp()
        let clock = DeviceClock("2026-10-30T12:00:00.000000Z")
        let jpeg = Data(repeating: 0xFF, count: 600)
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

        // Asked before the owner's second device downloads the file: URLSession would otherwise answer from its
        // cache, which is keyed by URL alone.
        let other = try Phone(stranger, clock: clock)
        await other.engine.sync()
        #expect(try other.repo.gyms().isEmpty)
        let anon = try anonTransport()
        // Refused outright or empty: either way a signed-out client reads nothing.
        #expect((try? await anon.pullGyms(since: nil))?.isEmpty ?? true)
        #expect((try? await anon.pullGymListings(since: nil))?.isEmpty ?? true)
        await #expect(throws: (any Error).self) { _ = try await anon.downloadPrivatePhoto(path: path) }
        await #expect(throws: (any Error).self) { _ = try await stranger.transport.downloadPrivatePhoto(path: path) }

        let second = try Phone(try await owner.onAnotherDevice(), clock: clock)
        await second.engine.sync()
        #expect(second.engine.status == .idle)
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

        try await owner.deleteAccount()
        try await stranger.deleteAccount()
    }
}
