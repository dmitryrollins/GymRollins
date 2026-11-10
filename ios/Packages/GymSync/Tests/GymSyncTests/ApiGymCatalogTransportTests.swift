import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// `ApiGymCatalogTransport` against a stub of the catalogue, moderation and photo routes: the paths, queries and bodies
/// of server/src/gyms, src/moderation and src/photos, and their answers.
@Suite struct ApiGymCatalogTransportTests {
    private let gymId = UUID(uuidString: "6F1C2A3B-0000-4000-8000-000000000001")!
    private let listingId = UUID(uuidString: "6F1C2A3B-0000-4000-8000-000000000002")!
    private let photo = "6f1c2a3b-0000-4000-8000-0000000000aa.jpg"
    /// The same name as the phone may hold it: an uppercase UUID (the server keeps names lowercase).
    private var upperPhoto: String { photo.dropLast(4).uppercased() + ".jpg" }

    private func signedIn(_ server: StubServer) -> ApiGymCatalogTransport {
        let session = StoredSession(token: "token-1", userId: UUID(), email: nil)
        return ApiGymCatalogTransport(api: server.client(sessions: InMemorySessionStore(session)))
    }

    private func body(_ request: SeenRequest?) -> [String: Any] { ((try? request?.json()) as? [String: Any]) ?? [:] }

    private var listingJSON: String {
        #"{"id": "\#(listingId)", "gym_id": "\#(gymId)", "item_id": "\#(UUID())", "kind_id": "cable-station", "#
            + #""brand": null, "model": null, "photo_path": "\#(photo)", "loads": {"type": "none"}, "quantity": 1, "#
            + #""notes": null, "status": "active", "confirm_count": 2, "is_mine": true, "confirmed_by_me": false}"#
    }

    @Test func aPublicGymIsAskedForByItsPlaceWithPlusSentAsPercent2B() async throws {
        let place = "ChIJ+ab/c="
        let server = StubServer { request in
            request.query["place"] == place
                ? .json(200, #"{"gym": {"id": "\#(gymId)", "name": "Iron Works", "address": null, "latitude": 52.5, "#
                    + #""longitude": 13.4, "maps_place_id": "\#(place)", "status": "active", "is_mine": false}}"#)
                : .json(200, #"{"gym": null}"#)
        }
        let found = try await signedIn(server).publicGym(mapsPlaceId: place)
        #expect(found == RemoteGym(id: gymId, name: "Iron Works", address: nil, latitude: 52.5, longitude: 13.4,
                                   mapsPlaceId: place))
        let request = try #require(server.requests.first)
        #expect(request.path == "/v1/gyms/public")
        #expect(request.url.absoluteString.contains("%2B") && !request.url.absoluteString.contains("+"))
        #expect(try await signedIn(server).publicGym(mapsPlaceId: "elsewhere") == nil)
    }

    @Test func listingsAreReadInPagesOfFiveHundredUntilAShortOne() async throws {
        let server = StubServer { _ in .json(200, #"{"rows": [\#(listingJSON)]}"#) }
        let read = try await signedIn(server).publicListings(gymId: gymId)
        #expect(read.listings.map(\.id) == [listingId])
        #expect(read.listings.first?.isMine == true && read.listings.first?.confirmCount == 2)
        #expect(read.isComplete)
        let request = try #require(server.requests.first)
        #expect(request.path == "/v1/gyms/\(gymId.uuidString.lowercased())/listings")
        #expect(request.query == ["offset": "0", "limit": "500"])

        var offsets: [Int] = []
        let full = try JSONSerialization.data(withJSONObject: [[:], [:]])
        let capped = try await ApiGymCatalogTransport.readListings(pageSize: 2, maxPages: 2) { start in
            offsets.append(start)
            return full
        }
        #expect(offsets == [0, 2])
        #expect(capped.capped && capped.skipped == 4)
    }

    @Test func itemsAndTheQueueAreReadFromRows() async throws {
        let server = StubServer { request in
            switch request.path {
            case "/v1/items":
                return .json(200, #"{"rows": [{"id": "\#(UUID())", "kind_id": "\#(request.query["kind"] ?? "")", "#
                    + #""brand": "Acme", "model": null, "photo_path": null, "photo_listing_id": null, "#
                    + #""gym_count": 3}]}"#)
            default:
                return .json(200, #"{"rows": [{"target_type": "listing", "target_id": "\#(listingId)", "#
                    + #""title": "Acme", "photo_path": null, "report_count": 3, "reasons": {"spam": 3}, "notes": [], "#
                    + #""status": "flagged", "#
                    + #""address": "Iron Works", "listing_notes": null}]}"#)
            }
        }
        let items = try await signedIn(server).publicItems(kindId: "cable-station")
        #expect(items.map(\.kindId) == ["cable-station"] && items.first?.gymCount == 3)
        let queue = try await signedIn(server).moderationQueue()
        #expect(queue.map(\.targetId) == [listingId] && queue.first?.reportCount == 3)
        #expect(server.requests.map(\.path) == ["/v1/items", "/v1/admin/queue"])
    }

    @Test func writesSendTheirArgumentsAsSnakeCaseBodiesAndReadObjectAnswers() async throws {
        let server = StubServer { request in
            switch request.path {
            case "/v1/gyms/find-or-create": return .json(200, #"{"id": "\#(gymId)"}"#)
            case "/v1/listings/share": return .json(200, #"{"status": "created", "listing_id": "\#(listingId)"}"#)
            case "/v1/blocks" where request.method == "DELETE": return .json(200, #"{"cleared": 2}"#)
            case "/v1/blocks", "/v1/admin/photo-deleted": return StubAnswer(status: 204, headers: [:], body: Data())
            case "/v1/reports": return .json(200, #"{"status": "already"}"#)
            case "/v1/admin/moderate": return .json(200, #"{"status": "removed", "photo_path": "\#(photo)"}"#)
            default: return .json(200, #"{"confirm_count": 4}"#)
            }
        }
        let transport = signedIn(server)
        let created = try await transport.findOrCreateGym(mapsPlaceId: "p-1", name: "Iron Works", address: nil,
                                                          latitude: 52.5, longitude: nil)
        #expect(created == gymId)
        let share = ShareRequest(listingId: listingId, gymId: gymId, kindId: "cable-station", brand: "Acme", model: nil,
                                 loads: .stack(maxKg: 90, stepKg: 5), quantity: 2, notes: "by the door",
                                 photoPath: upperPhoto, forceNew: true)
        #expect(try await transport.share(share) == .created(listingId))
        #expect(try await transport.confirm(listingId: listingId) == 4)
        try await transport.report(targetType: .listing, targetId: listingId, reason: .personInPhoto, note: "a face")
        try await transport.blockAuthor(targetType: .gym, targetId: gymId)
        #expect(try await transport.unblockAll() == 2)
        #expect(try await transport.moderate(targetType: .listing, targetId: listingId, action: .remove) == photo)
        try await transport.moderationPhotoDeleted(path: photo)

        let seen = server.requests
        #expect(seen.map { "\($0.method) \($0.path)" } == [
            "POST /v1/gyms/find-or-create", "POST /v1/listings/share",
            "POST /v1/listings/\(listingId.uuidString.lowercased())/confirm", "POST /v1/reports", "POST /v1/blocks",
            "DELETE /v1/blocks", "POST /v1/admin/moderate", "POST /v1/admin/photo-deleted",
        ])
        #expect(body(seen[0])["maps_place_id"] as? String == "p-1" && body(seen[0])["latitude"] as? Double == 52.5)
        let shared = body(seen[1])
        #expect(shared["listing_id"] as? String == listingId.uuidString.lowercased())
        #expect(shared["gym_id"] as? String == gymId.uuidString.lowercased())
        #expect(shared["photo_path"] as? String == photo && shared["force_new"] as? Bool == true)
        #expect((shared["loads"] as? [String: Any])?["maxKg"] as? Double == 90)
        #expect(shared["kind_id"] as? String == "cable-station" && shared["quantity"] as? Int == 2)
        #expect(shared["notes"] as? String == "by the door" && shared["brand"] as? String == "Acme")
        #expect(body(seen[3])["target_type"] as? String == "listing")
        #expect(body(seen[3])["reason"] as? String == "person-in-photo")
        #expect(body(seen[3])["note"] as? String == "a face")
        #expect(body(seen[4])["target_id"] as? String == gymId.uuidString.lowercased())
        #expect(body(seen[6])["action"] as? String == "remove")
        #expect(body(seen[7])["path"] as? String == photo)
    }

    @Test func isAdminAsksOnlyWithASession() async throws {
        let server = StubServer { _ in .json(200, #"{"admin": true}"#) }
        #expect(try await ApiGymCatalogTransport(api: server.client()).isAdmin() == false)
        #expect(server.requests.isEmpty)
        #expect(try await signedIn(server).isAdmin())
        #expect(server.requests.map(\.path) == ["/v1/admin/me"])
    }

    @Test func aSharedPhotoGoesUpAsJpegAndARepeatIsDone() async throws {
        let server = StubServer { request in
            request.headers["Content-Type"] == "image/jpeg"
                ? .json(409, #"{"error": {"code": "duplicate", "message": "Already uploaded."}}"#)
                : .json(400, #"{"error": {"code": "bad_request", "message": "wrong type"}}"#)
        }
        let transport = signedIn(server)
        #expect(try await transport.uploadSharedPhoto(Data([0xFF, 0xD8, 0xFF]), name: upperPhoto) == photo)
        let request = try #require(server.requests.first)
        #expect(request.method == "PUT" && request.path == "/v1/photos/shared/\(photo)")
        #expect(request.body == Data([0xFF, 0xD8, 0xFF]))
        await #expect(throws: GymCatalogError.rejected("not a photo name")) {
            _ = try await transport.uploadSharedPhoto(Data(), name: "../secret.jpg")
        }
        await #expect(throws: GymCatalogError.signedOut) {
            _ = try await ApiGymCatalogTransport(api: server.client()).uploadSharedPhoto(Data(), name: photo)
        }
        #expect(server.requests.count == 1)
    }

    @Test func deletingAllPhotosListsRemovesAndListsAgain() async throws {
        let names = ["gym-photos": "6f1c2a3b-0000-4000-8000-0000000000b1.jpg",
                     "gym-photos-private": "6f1c2a3b-0000-4000-8000-0000000000b2.jpg"]
        let remaining = Remaining(names)
        let server = StubServer { request in
            if request.method == "GET" {
                let rows = remaining.value.map { #"{"bucket_id": "\#($0.key)", "name": "\#($0.value)"}"# }
                return .json(200, #"{"rows": [\#(rows.joined(separator: ","))]}"#)
            }
            remaining.remove(request.path)
            return StubAnswer(status: 204, headers: [:], body: Data())
        }
        try await signedIn(server).deleteAllPhotos()
        let deletes = server.requests.filter { $0.method == "DELETE" }.map(\.path).sorted()
        #expect(deletes == ["/v1/photos/private/\(names["gym-photos-private"]!)",
                            "/v1/photos/shared/\(names["gym-photos"]!)"])
        #expect(server.requests.filter { $0.method == "GET" }.count == 2)
        try await signedIn(server).detachAllPhotos()
        #expect(server.requests.last.map { "\($0.method) \($0.path)" } == "POST /v1/photos/detach")
    }

    @Test func refusalsReachTheQueuesCases() async throws {
        let answers: [(StubAnswer, GymCatalogError)] = [
            (.json(401, #"{"error": {"code": "signed_out", "message": "Sign in required."}}"#), .signedOut),
            (.json(422, #"{"error": {"code": "daily_limit", "message": "You've shared a lot today."}}"#), .dailyLimit),
            (.json(503, #"{"error": {"code": "try_again", "message": "Try again."}}"#), .offline),
        ]
        for (answer, expected) in answers {
            let server = StubServer { _ in answer }
            await #expect(throws: expected) { _ = try await signedIn(server).confirm(listingId: listingId) }
        }
    }

    @Test func aPublicPhotoIsTheWorkersPublicRoute() throws {
        let server = StubServer { _ in .json(200, "{}") }
        let url = try #require(signedIn(server).publicPhotoURL(path: upperPhoto))
        #expect(url.absoluteString == "\(server.baseURL.absoluteString)/photos/shared/\(photo)")
        #expect(signedIn(server).publicPhotoURL(path: "../x.jpg") == nil)
    }
}

/// The photos a stub server still holds, by bucket.
private final class Remaining: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String]
    init(_ names: [String: String]) { self.names = names }
    var value: [String: String] { lock.withLock { names } }
    func remove(_ path: String) { lock.withLock { names = names.filter { !path.hasSuffix($0.value) } } }
}
