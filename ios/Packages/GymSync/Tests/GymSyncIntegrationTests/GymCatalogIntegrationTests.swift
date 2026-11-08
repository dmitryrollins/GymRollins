import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// `ApiGymCatalogTransport` against the local Worker: the catalogue, moderation and photo routes the app relies on.
@MainActor
@Suite(.enabled(if: apiConfigured, "Set API_URL (scripts/test-sync-integration.sh) to run against a local Worker"))
struct GymCatalogIntegrationTests {
    private func catalog(_ account: Account) -> ApiGymCatalogTransport { account.catalog }

    /// A phone with no account: the catalogue answers it `.signedOut`, reads included.
    private func anonCatalog() throws -> ApiGymCatalogTransport { try GymIntegration.signedOutCatalog() }

    private func freshPlace() -> String { "it-\(UUID().uuidString.lowercased())" }

    /// A JPEG: the server checks the bytes as well as the declared type.
    private func photo() -> Data { GymIntegration.jpeg }

    private func photoName() -> String { "\(UUID().uuidString.lowercased()).jpg" }

    /// Every test has a brand of its own. Suites run in parallel and share the server, and an item with a brand only
    /// the test's account used is deleted with that account: two tests sharing "Hammer" could delete each other's
    /// item between `share_listing` finding it and inserting the listing.
    private let ownBrand = "Hammer \(UUID().uuidString.prefix(8))"

    private func request(_ id: UUID = UUID(), gym: UUID, kind: String = "cable-station", brand: String? = nil,
                         brandless: Bool = false, photo: String? = nil, forceNew: Bool = false) -> ShareRequest {
        ShareRequest(listingId: id, gymId: gym, kindId: kind, brand: brandless ? nil : (brand ?? ownBrand),
                     model: nil,
                     loads: .stack(maxKg: 90, stepKg: 5), quantity: 2, notes: "by the door", photoPath: photo,
                     forceNew: forceNew)
    }

    private func gym(_ transport: ApiGymCatalogTransport, place: String) async throws -> UUID {
        try await transport.findOrCreateGym(mapsPlaceId: place, name: "Iron Works", address: "1 Main St",
                                            latitude: 52.5, longitude: 13.4)
    }

    @Test func aSharedListingWithAPhotoReadsBackThroughAnotherAccountButNotSignedOut() async throws {
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

        await #expect(throws: GymCatalogError.signedOut) { _ = try await anonCatalog().publicGym(mapsPlaceId: place) }
        let reader = try await Account.signUp()
        let anon = catalog(reader)
        let found = try #require(try await anon.publicGym(mapsPlaceId: place))
        #expect(found.id == gymId)
        #expect(found.name == "Iron Works")
        let listings = try await anon.publicListings(gymId: gymId).listings
        let listing = try #require(listings.first)
        #expect(listing.id == listingId)
        #expect(listing.kindId == "cable-station")
        #expect(listing.brand == ownBrand)
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
        try await reader.deleteAccount()
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

        try await transport.deleteSharedPhoto(path: name)
        // The name stays a listing's after its object went (photo_name_in_use): every photo refusal is one answer.
        await #expect(throws: GymCatalogError.photoRefused) {
            _ = try await transport.uploadSharedPhoto(photo(), name: name)
        }
        try await user.deleteAccount()
    }

    private func isServed(_ transport: ApiGymCatalogTransport, _ name: String) async throws -> Bool {
        try await GymIntegration.isServed(name)
    }

    @Test func onlyTheOwnerCanDeleteAnUploadedPhoto() async throws {
        let owner = try await Account.signUp()
        let other = try await Account.signUp()
        let gymId = try await gym(catalog(owner), place: freshPlace())
        let name = photoName()
        _ = try await catalog(owner).uploadSharedPhoto(photo(), name: name)
        #expect(try await !isServed(catalog(owner), name), "an upload no listing uses is not served")
        _ = try await catalog(owner).share(request(gym: gymId, photo: name))
        #expect(try await isServed(catalog(owner), name))

        await #expect(throws: GymCatalogError.notAllowed) { try await catalog(other).deleteSharedPhoto(path: name) }
        #expect(try await isServed(catalog(owner), name), "another user's delete removes nothing")
        try await catalog(owner).deleteSharedPhoto(path: name)
        #expect(try await !isServed(catalog(owner), name))
        try await catalog(owner).deleteSharedPhoto(path: name) // already gone: fine
        try await owner.deleteAccount()
        try await other.deleteAccount()
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
        let user = try await Account.signUp()
        #expect(try await catalog(user).publicGym(mapsPlaceId: freshPlace()) == nil)
        try await user.deleteAccount()
    }

    // MARK: Reports and blocks

    @Test func aReportBlockAndUnblockGoThroughTheServer() async throws {
        let author = try await Account.signUp()
        let reader = try await Account.signUp()
        let gymId = try await gym(catalog(author), place: freshPlace())
        let kept = UUID(), reported = UUID()
        _ = try await catalog(author).share(request(kept, gym: gymId, kind: "cable-station", brandless: true))
        _ = try await catalog(author).share(request(reported, gym: gymId, kind: "leg-press", brandless: true))

        // Nothing to say about the author's own listing: the server answers `own`, which is not an error.
        try await catalog(author).report(targetType: .listing, targetId: reported, reason: .spam, note: nil)
        try await catalog(reader).report(targetType: .listing, targetId: reported, reason: .wrongInfo, note: "a note")
        try await catalog(reader).report(targetType: .listing, targetId: reported, reason: .wrongInfo, note: nil)
        try await catalog(reader).report(targetType: .gym, targetId: gymId, reason: .notHereAnymore, note: nil)

        await #expect(throws: GymCatalogError.unknownTarget) {
            try await catalog(reader).report(targetType: .listing, targetId: UUID(), reason: .spam, note: nil)
        }
        await #expect(throws: GymCatalogError.noteRefused) {
            try await catalog(reader).report(targetType: .listing, targetId: kept, reason: .other, note: "bad\u{7}note")
        }
        await #expect(throws: GymCatalogError.signedOut) {
            try await anonCatalog().report(targetType: .listing, targetId: kept, reason: .spam, note: nil)
        }

        try await catalog(reader).blockAuthor(targetType: .listing, targetId: kept)
        #expect(try await catalog(reader).publicListings(gymId: gymId).listings.isEmpty)
        #expect(try await catalog(author).publicListings(gymId: gymId).listings.count == 2)
        #expect(try await catalog(reader).unblockAll() == 1)
        #expect(try await catalog(reader).publicListings(gymId: gymId).listings.count == 2)
        #expect(try await catalog(reader).unblockAll() == 0)
        try await author.deleteAccount()
        try await reader.deleteAccount()
    }
}
