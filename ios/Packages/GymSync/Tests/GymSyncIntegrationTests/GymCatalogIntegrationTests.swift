import Foundation
import GymCore
import GymData
import Supabase
import Testing
@testable import GymSync

/// `SupabaseGymCatalogTransport` against the local stack: the views, functions and Storage rules the app relies on.
@MainActor
@Suite(.enabled(if: supabaseConfigured, "Set SUPABASE_URL and SUPABASE_ANON_KEY to run against local Supabase"))
struct GymCatalogIntegrationTests {
    private func catalog(_ account: Account) -> SupabaseGymCatalogTransport {
        SupabaseGymCatalogTransport(client: account.auth.client)
    }

    private func anonCatalog() throws -> SupabaseGymCatalogTransport {
        SupabaseGymCatalogTransport(client: try IntegrationEnv.config().makeClient(storage: InMemoryAuthStorage()))
    }

    private func freshPlace() -> String { "it-\(UUID().uuidString.lowercased())" }

    /// A JPEG-typed payload; Storage checks the declared type, not the bytes.
    private func photo() -> Data { Data(repeating: 0xFF, count: 600) }

    private func photoName() -> String { "\(UUID().uuidString.lowercased()).jpg" }

    private func request(_ id: UUID = UUID(), gym: UUID, kind: String = "cable-station", brand: String? = "Hammer",
                         photo: String? = nil, forceNew: Bool = false) -> ShareRequest {
        ShareRequest(listingId: id, gymId: gym, kindId: kind, brand: brand, model: nil,
                     loads: .stack(maxKg: 90, stepKg: 5), quantity: 2, notes: "by the door", photoPath: photo,
                     forceNew: forceNew)
    }

    private func gym(_ transport: SupabaseGymCatalogTransport, place: String) async throws -> UUID {
        try await transport.findOrCreateGym(mapsPlaceId: place, name: "Iron Works", address: "1 Main St",
                                            latitude: 52.5, longitude: 13.4)
    }

    @Test func aSharedListingWithAPhotoReadsBackThroughAnAnonClient() async throws {
        let user = try await Account.signUp()
        let transport = catalog(user)
        let place = freshPlace()
        let gymId = try await gym(transport, place: place)
        #expect(try await gym(transport, place: place) == gymId)

        let name = photoName()
        #expect(try await transport.uploadSharedPhoto(photo(), name: name) == name)
        let listingId = UUID()
        #expect(try await transport.share(request(listingId, gym: gymId, photo: name)) == .created(listingId))
        #expect(try await transport.share(request(listingId, gym: gymId, photo: name)) == .created(listingId))

        let anon = try anonCatalog()
        let found = try #require(try await anon.publicGym(mapsPlaceId: place))
        #expect(found.id == gymId)
        #expect(found.name == "Iron Works")
        let listings = try await anon.publicListings(gymId: gymId).listings
        let listing = try #require(listings.first)
        #expect(listing.id == listingId)
        #expect(listing.kindId == "cable-station")
        #expect(listing.brand == "Hammer")
        #expect(listing.loads == .stack(maxKg: 90, stepKg: 5))
        #expect(listing.quantity == 2)
        #expect(listing.photoPath == name)
        #expect(!listing.isMine)
        #expect(!listing.confirmedByMe)

        let mine = try #require(try await transport.publicListings(gymId: gymId).listings.first)
        #expect(mine.isMine)

        let items = try await anon.publicItems(kindId: "cable-station")
        let item = try #require(items.first { $0.id == listing.itemId })
        #expect(item.photoPath == name)
        #expect(item.photoListingId == listingId)

        let url = try #require(anon.publicPhotoURL(path: name))
        #expect(!url.absoluteString.contains(user.userId.uuidString.lowercased()))
        let (_, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        try await user.deleteAccount()
    }

    @Test func aSecondShareOfTheKindReturnsDuplicatesUnlessForced() async throws {
        let first = try await Account.signUp()
        let second = try await Account.signUp()
        let gymId = try await gym(catalog(first), place: freshPlace())
        let original = UUID()
        _ = try await catalog(first).share(request(original, gym: gymId))

        let result = try await catalog(second).share(request(gym: gymId))
        guard case let .duplicates(found) = result else { Issue.record("expected duplicates, got \(result)"); return }
        #expect(found.map(\.id) == [original])
        #expect(found.first?.kindId == "cable-station")
        #expect(found.first?.loads == .stack(maxKg: 90, stepKg: 5))

        let forced = UUID()
        #expect(try await catalog(second).share(request(forced, gym: gymId, forceNew: true)) == .created(forced))
        let listings = try await catalog(second).publicListings(gymId: gymId).listings
        #expect(Set(listings.map(\.id)) == [original, forced])
        #expect(try await catalog(second).confirm(listingId: original) == 1)
        #expect(try await catalog(second).confirm(listingId: original) == 1)
        try await first.deleteAccount()
        try await second.deleteAccount()
    }

    @Test func uploadingTheSamePhotoTwiceSucceeds() async throws {
        let user = try await Account.signUp()
        let transport = catalog(user)
        let name = photoName()
        #expect(try await transport.uploadSharedPhoto(photo(), name: name) == name)
        #expect(try await transport.uploadSharedPhoto(photo(), name: name) == name)
        try await user.deleteAccount()
    }

    @Test func aNameAListingUsesCannotBeUploadedAgain() async throws {
        let user = try await Account.signUp()
        let transport = catalog(user)
        let gymId = try await gym(transport, place: freshPlace())
        let name = photoName()
        _ = try await transport.uploadSharedPhoto(photo(), name: name)
        let listingId = UUID()
        _ = try await transport.share(request(listingId, gym: gymId, photo: name))

        _ = try await user.auth.client.storage.from("gym-photos").remove(paths: [name])
        await #expect(throws: GymCatalogError.self) {
            _ = try await transport.uploadSharedPhoto(photo(), name: name)
        }
        try await user.deleteAccount()
    }

    @Test func anotherUsersUploadedPhotoCannotBeShared() async throws {
        let owner = try await Account.signUp()
        let thief = try await Account.signUp()
        let gymId = try await gym(catalog(owner), place: freshPlace())
        let name = photoName()
        _ = try await catalog(owner).uploadSharedPhoto(photo(), name: name)

        await #expect(throws: GymCatalogError.photoMissing) {
            _ = try await catalog(thief).share(request(gym: gymId, photo: name))
        }
        try await owner.deleteAccount()
        try await thief.deleteAccount()
    }

    @Test func anAnonymousWriteIsSignedOutAndAnUnknownGymIsNotShareable() async throws {
        let anon = try anonCatalog()
        await #expect(throws: GymCatalogError.signedOut) {
            _ = try await anon.confirm(listingId: UUID())
        }
        await #expect(throws: GymCatalogError.signedOut) {
            _ = try await anon.uploadSharedPhoto(photo(), name: photoName())
        }
        let user = try await Account.signUp()
        await #expect(throws: GymCatalogError.gymNotShareable) {
            _ = try await catalog(user).share(request(gym: UUID()))
        }
        try await user.deleteAccount()
    }

    @Test func aGymNobodyHasSharedYetIsAbsent() async throws {
        #expect(try await anonCatalog().publicGym(mapsPlaceId: freshPlace()) == nil)
    }
}
