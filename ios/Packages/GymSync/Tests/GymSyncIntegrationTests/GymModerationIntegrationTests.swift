import Foundation
import GymData
import Testing
@testable import GymSync

/// The admin list against the local Worker. `scripts/test-sync-integration.sh` makes any account named
/// `sync-admin-*@test.local` an admin when it signs up.
@MainActor
@Suite(.enabled(if: apiConfigured, "Set API_URL (scripts/test-sync-integration.sh) to run against a local Worker"))
struct GymModerationIntegrationTests {
    /// This test's own brand: parallel tests that share one would delete each other's item with their accounts.
    private let brand = "Hammer \(UUID().uuidString.prefix(8))"

    private func catalog(_ account: Account) -> ApiGymCatalogTransport { account.catalog }

    private func signUpAdmin() async throws -> Account {
        let account = try Account.fresh(email: "sync-admin-\(UUID().uuidString.lowercased())@test.local")
        try await account.auth.signUp(email: account.email, password: IntegrationEnv.password)
        return account
    }

    private func isServed(_ transport: ApiGymCatalogTransport, _ name: String) async throws -> Bool {
        try await GymIntegration.isServed(name)
    }

    @Test func anAdminRemovesAnotherUsersFlaggedListingAndItsPhotoGoesFromStorage() async throws {
        let author = try await Account.signUp()
        let admin = try await signUpAdmin()
        let plain = try await Account.signUp()
        var reporters: [Account] = []
        for _ in 0..<3 { reporters.append(try await Account.signUp()) }

        let gymId = try await catalog(author).findOrCreateGym(mapsPlaceId: "it-\(UUID().uuidString.lowercased())",
                                                              name: "Iron Works", address: nil, latitude: 52.5,
                                                              longitude: 13.4)
        let name = "\(UUID().uuidString.lowercased()).jpg"
        _ = try await catalog(author).uploadSharedPhoto(GymIntegration.jpeg, name: name)
        let listingId = UUID()
        let request = ShareRequest(listingId: listingId, gymId: gymId, kindId: "cable-station", brand: brand,
                                   model: nil, loads: .stack(maxKg: 90, stepKg: 5), quantity: 1, notes: nil,
                                   photoPath: name, forceNew: false)
        _ = try await catalog(author).share(request)
        for reporter in reporters {
            try await catalog(reporter).report(targetType: .listing, targetId: listingId, reason: .personInPhoto,
                                               note: nil)
        }

        #expect(try await catalog(admin).isAdmin())
        #expect(try await !catalog(plain).isAdmin())
        await #expect(throws: GymCatalogError.notAllowed) { _ = try await catalog(plain).moderationQueue() }
        await #expect(throws: GymCatalogError.notAllowed) {
            _ = try await catalog(plain).moderate(targetType: .listing, targetId: listingId, action: .remove)
        }

        let queued = try #require(try await catalog(admin).moderationQueue().first { $0.targetId == listingId })
        #expect(queued.targetType == .listing)
        #expect(queued.title == brand)
        #expect(queued.status == .flagged)
        #expect(queued.reportCount == 3)
        #expect(queued.reasons == [.init(reason: "person-in-photo", count: 3)])
        #expect(queued.photoPath == name)
        #expect(try await isServed(catalog(admin), name))

        let photo = try await catalog(admin).moderate(targetType: .listing, targetId: listingId, action: .remove)
        #expect(photo == name)
        try await catalog(admin).deleteSharedPhoto(path: name)
        #expect(try await !isServed(catalog(admin), name), "an admin's delete reaches a removed listing's photo")
        // The name stays on a removed listing until the app confirms the object is gone (moderation_photo_deleted), so
        // a failed delete can be retried: the queue still shows it, as removed and still naming the photo.
        let waiting = try #require(try await catalog(admin).moderationQueue().first { $0.targetId == listingId })
        #expect(waiting.status == .removed && waiting.photoPath == name)
        #expect(try await catalog(admin).moderate(targetType: .listing, targetId: listingId, action: .remove) == name,
                "removing again hands the same path out")
        try await catalog(admin).moderationPhotoDeleted(path: name)
        #expect(try await !catalog(admin).moderationQueue().contains { $0.targetId == listingId },
                "once the server hears the object is gone, the listing leaves the queue")

        for account in [author, admin, plain] + reporters { try await account.deleteAccount() }
    }
}
