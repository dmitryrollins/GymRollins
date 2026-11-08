import Foundation
import GymData
import Testing
@testable import GymSync

/// Account deletion and the photos the account owns, against the local Worker: the app removes them through
/// `/v1/photos` first, and the server refuses to delete the account while any remain.
@MainActor
@Suite(.enabled(if: apiConfigured, "Set API_URL (scripts/test-sync-integration.sh) to run against a local Worker"))
struct GymAccountPhotosIntegrationTests {
    private func catalog(_ account: Account) -> ApiGymCatalogTransport { account.catalog }

    private func photoName() -> String { "\(UUID().uuidString.lowercased()).jpg" }

    /// Uploads to a bucket as the phone does: shared photos through the share queue's transport, private ones
    /// through sync's.
    private func upload(_ account: Account, bucket: String, name: String) async throws {
        if bucket == "gym-photos" {
            _ = try await account.catalog.uploadSharedPhoto(GymIntegration.jpeg, name: name)
        } else {
            _ = try await account.transport.uploadPrivatePhoto(GymIntegration.jpeg, name: name)
        }
    }

    private func owned(_ account: Account) async throws -> [OwnedPhoto] {
        let body = try await account.auth.api.data("GET", "/v1/photos/mine").body
        return try OwnedPhotos.list(from: GymCatalogRows.array(in: body, key: "rows"))
    }

    @Test func deletingAnAccountRemovesItsPhotosAndKeepsTheSharedListing() async throws {
        let user = try await Account.signUp()
        let gymId = try await catalog(user).findOrCreateGym(
            mapsPlaceId: "it-\(UUID().uuidString.lowercased())", name: "Iron Works", address: nil, latitude: 52.5,
            longitude: 13.4)
        let shared = photoName(), orphan = photoName(), privateName = photoName()
        try await upload(user, bucket: "gym-photos", name: shared)
        try await upload(user, bucket: "gym-photos", name: orphan)
        try await upload(user, bucket: "gym-photos-private", name: privateName)
        let listingId = UUID()
        _ = try await catalog(user).share(ShareRequest(
            listingId: listingId, gymId: gymId, kindId: "cable-station", brand: nil, model: nil,
            loads: .stack(maxKg: 90, stepKg: 5), quantity: 1, notes: "mine", photoPath: shared, forceNew: false))
        #expect(try await owned(user).count == 3, "the orphan and the private photo are listed too")

        try await user.deleteAccount()

        // Catalogue reads need a session now, so another account reads what stayed.
        let reader = try await Account.signUp()
        let listings = try await reader.catalog.publicListings(gymId: gymId).listings
        let listing = try #require(listings.first { $0.id == listingId })
        #expect(listing.photoPath == nil)
        #expect(listing.notes == nil)
        #expect(try await !GymIntegration.isServed(shared))
        #expect(try await !GymIntegration.isServed(orphan))
        try await reader.deleteAccount()
    }

    @Test func theServerRefusesToDeleteWhileAPhotoRemains() async throws {
        let user = try await Account.signUp()
        try await upload(user, bucket: "gym-photos-private", name: photoName())
        let refused = await #expect(throws: AuthFailure.self) { try await user.auth.deleteAccount() }
        #expect(refused?.message.contains("still being removed") == true)
        #expect(user.auth.state.userId == user.userId, "the account stays signed in")
        #expect(try await owned(user).count == 1)

        try await catalog(user).deleteAllPhotos()
        try await catalog(user).deleteAllPhotos() // nothing left, and that is fine
        try await user.deleteAccount()
    }

    @Test func removingAPhotoAlreadyGoneIsNotAFailure() async throws {
        let user = try await Account.signUp()
        let name = photoName()
        try await upload(user, bucket: "gym-photos", name: name)
        try await catalog(user).deleteSharedPhoto(path: name)
        try await catalog(user).deleteAllPhotos()
        try await user.deleteAccount()
    }
}
