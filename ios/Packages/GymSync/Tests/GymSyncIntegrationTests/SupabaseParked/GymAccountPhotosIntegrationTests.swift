import Foundation
import GymData
import Supabase
import Testing
@testable import GymSync

/// Account deletion and the photos the account owns, against the local stack: the app removes them through Storage
/// first, and the server refuses to delete the account while any remain.
@MainActor
@Suite(.enabled(if: supabaseConfigured, "Set SUPABASE_URL and SUPABASE_ANON_KEY to run against local Supabase"))
struct GymAccountPhotosIntegrationTests {
    private func catalog(_ account: Account) -> SupabaseGymCatalogTransport {
        SupabaseGymCatalogTransport(client: account.auth.client)
    }

    private func photoName() -> String { "\(UUID().uuidString.lowercased()).jpg" }

    private func upload(_ account: Account, bucket: String, name: String) async throws {
        _ = try await account.auth.client.storage.from(bucket).upload(
            name, data: Data(repeating: 0xFF, count: 600),
            options: FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: false))
    }

    private func owned(_ account: Account) async throws -> [OwnedPhoto] {
        let data = try await account.auth.client.rpc("my_gym_photos").execute().data
        return try SupabaseGymCatalogTransport.ownedPhotos(from: data)
    }

    private func isServed(_ account: Account, _ name: String) async throws -> Bool {
        let url = try #require(catalog(account).publicPhotoURL(path: name))
        let (_, response) = try await URLSession.shared.data(for: URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        return (response as? HTTPURLResponse)?.statusCode == 200
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

        let anon = SupabaseGymCatalogTransport(
            client: try IntegrationEnv.config().makeClient(storage: InMemoryAuthStorage()))
        let listing = try #require(try await anon.publicListings(gymId: gymId).listings.first { $0.id == listingId })
        #expect(listing.photoPath == nil)
        #expect(listing.notes == nil)
        #expect(try await !isServed(Account.fresh(email: IntegrationEnv.uniqueEmail()), shared))
        #expect(try await !isServed(Account.fresh(email: IntegrationEnv.uniqueEmail()), orphan))
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
