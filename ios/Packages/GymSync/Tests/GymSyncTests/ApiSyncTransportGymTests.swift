import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// Private gyms, listings and their photos through `ApiSyncTransport` against a stub of `/v1/sync/gyms`,
/// `/v1/sync/gym-listings` and `/v1/photos/private` (server/src/sync/entities.ts, src/photos/routes.ts).
@Suite struct ApiSyncTransportGymTests {
    private let t0 = SyncDate.parse("2026-11-08T08:00:00.123456Z")!
    private let photo = "6f1c2a3b-0000-4000-8000-0000000000cc.jpg"
    /// The same name as the phone may hold it: an uppercase UUID (the server keeps names lowercase).
    private var upperPhoto: String { photo.dropLast(4).uppercased() + ".jpg" }

    private func rows(_ request: SeenRequest?) -> [[String: Any]] {
        ((try? request?.json()) as? [String: Any])?["rows"] as? [[String: Any]] ?? []
    }

    @Test func gymsAndListingsGoUpAndComeBackOnTheirOwnPaths() async throws {
        let gym = SyncedGym(id: UUID(), name: "Garage", address: nil, latitude: nil, longitude: nil)
        let listingId = UUID()
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("POST", _): return .json(200, #"{"acks": []}"#)
            case (_, "/v1/sync/gym-listings"):
                return .json(200, #"{"rows": [{"id": "\#(listingId)", "gym_id": "\#(gym.id)", "#
                    + #""item_id": "\#(UUID())", "#
                    + #""visibility": "private", "photo_path": null, "loads": {"type": "fixed", "kg": [20, 24]}, "#
                    + #""quantity": 1, "notes": null, "private_brand": "Secret", "private_model": null, "#
                    + #""client_updated_at": "2026-11-08T08:00:00.123456Z", "deleted_at": null, "#
                    + #""updated_at": "2026-11-08T09:00:00.100000Z", "equipment_items": {"kind_id": "dumbbells"}}]}"#)
            default: return .json(200, #"{"rows": []}"#)
            }
        }
        let transport = ApiSyncTransport(api: server.client())
        #expect(transport.servesGyms)
        _ = try await transport.push(gyms: [GymDTO(SyncRow(value: gym, clientUpdatedAt: t0))])
        let pulled = try await transport.pullGymListings(since: nil)
        _ = try await transport.pullGyms(since: nil)

        #expect(server.requests.map { "\($0.method) \($0.path)" } == [
            "POST /v1/sync/gyms", "GET /v1/sync/gym-listings", "GET /v1/sync/gyms",
        ])
        #expect(rows(server.requests.first).first?["visibility"] as? String == "private")
        let listing = try #require(pulled.first?.toDomain())
        #expect(listing.value.kindId == "dumbbells" && listing.value.brand == "Secret")
        #expect(listing.value.loads == .fixed(kg: [20, 24]))
    }

    @Test func aListingWhosePhotoTheServerLacksAsksForTheUploadAgain() async throws {
        let server = StubServer { _ in
            .json(422, #"{"error": {"code": "photo_missing", "message": "That photo isn't uploaded."}}"#)
        }
        let listing = SyncedListing(id: UUID(), gymId: UUID(), kindId: "dumbbells", brand: nil, model: nil,
                                    loads: .fixed(kg: [20]), quantity: 1, notes: nil, photoFile: nil,
                                    remotePhotoPath: photo)
        await #expect(throws: PrivatePhotoMissing.self) {
            _ = try await ApiSyncTransport(api: server.client())
                .push(gymListings: [GymListingDTO(SyncRow(value: listing, clientUpdatedAt: t0))])
        }
    }

    @Test func theCapsRefuseTheRowWithTheAppsWords() async throws {
        let words = "You've reached the limit of gyms on one account."
        let server = StubServer { _ in .json(422, #"{"error": {"code": "too_many_gyms", "message": "\#(words)"}}"#) }
        let gym = SyncedGym(id: UUID(), name: "One more", address: nil, latitude: nil, longitude: nil)
        await #expect(throws: SyncRecordRejected(code: "too_many_gyms", message: words)) {
            let row = GymDTO(SyncRow(value: gym, clientUpdatedAt: t0))
            _ = try await ApiSyncTransport(api: server.client()).push(gyms: [row])
        }
    }

    @Test func aPrivatePhotoGoesUpAsJpegComesBackAndGoes() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let server = StubServer { request in
            switch request.method {
            case "PUT": return .json(409, #"{"error": {"code": "duplicate", "message": "Already uploaded."}}"#)
            case "GET": return StubAnswer(status: 200, headers: ["Content-Type": "image/jpeg"], body: jpeg)
            default: return StubAnswer(status: 204, headers: [:], body: Data())
            }
        }
        let transport = ApiSyncTransport(api: server.client())
        #expect(try await transport.uploadPrivatePhoto(jpeg, name: upperPhoto) == photo)
        #expect(try await transport.downloadPrivatePhoto(path: photo) == jpeg)
        try await transport.deletePrivatePhoto(path: photo)
        let path = "/v1/photos/private/\(photo)"
        #expect(server.requests.map { "\($0.method) \($0.path)" } == ["PUT \(path)", "GET \(path)", "DELETE \(path)"])
        #expect(server.requests.first?.headers["Content-Type"] == "image/jpeg")
        await #expect(throws: URLError.self) { _ = try await transport.downloadPrivatePhoto(path: "../secret.jpg") }
        #expect(server.requests.count == 3)
    }
}
