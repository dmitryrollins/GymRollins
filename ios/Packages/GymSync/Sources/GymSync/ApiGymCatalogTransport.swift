import Foundation
import GymCore
import GymData

/// `GymCatalogTransport` over the API: the shared catalogue (`/v1/gyms`, `/v1/items`, `/v1/listings`), moderation
/// (`/v1/reports`, `/v1/blocks`, `/v1/admin`) and shared photos (`/v1/photos`, read at `/photos/shared`); see
/// server/src/gyms, src/moderation and src/photos. Every call but the public photo URL needs the app session: a
/// signed-out phone hears `.signedOut`, reads included (spec section 3; Supabase let the anon key read the views).
public struct ApiGymCatalogTransport: GymCatalogTransport {
    /// A gym holds at most `DomainLimits.gymActiveListingsMax` (300) active listings, so one page covers it; two pages
    /// is the most this reads, and a gym past that is reported as partial instead of looped on.
    static let pageSize = 500
    static let maxPages = 2

    let api: ApiClient

    public init(api: ApiClient) { self.api = api }

    var hasSession: Bool { api.sessions.load() != nil }

    // MARK: Reads

    public func publicGym(mapsPlaceId: String) async throws -> RemoteGym? {
        // ApiClient sends "+" as %2B: a bare "+" in a query is a space to the server, and place ids can hold one.
        let body = try await call {
            try await api.data("GET", "/v1/gyms/public", query: [URLQueryItem(name: "place", value: mapsPlaceId)]).body
        }
        return try GymCatalogRows.gyms(from: GymCatalogRows.array(in: body, key: "gym")).rows.first
    }

    public func publicListings(gymId: UUID) async throws -> PublicListings {
        try await Self.readListings { start in
            let query = [URLQueryItem(name: "offset", value: String(start)),
                         URLQueryItem(name: "limit", value: String(Self.pageSize))]
            let path = "/v1/gyms/\(Self.text(gymId))/listings"
            let body = try await call { try await api.data("GET", path, query: query).body }
            return try GymCatalogRows.array(in: body, key: "rows")
        }
    }

    /// Reads pages until one is short or `maxPages` is used up; the second case comes back marked as capped.
    static func readListings(pageSize: Int = Self.pageSize, maxPages: Int = Self.maxPages,
                             page: (Int) async throws -> Data) async throws -> PublicListings {
        var found: [RemoteListing] = []
        var skipped = 0
        var start = 0
        for _ in 0..<maxPages {
            let data = try await page(start)
            let decoded = try GymCatalogRows.listings(from: data)
            found += decoded.rows
            skipped += decoded.skipped
            let count = GymCatalogRows.rawCount(of: data)
            if count < pageSize { return PublicListings(listings: found, skipped: skipped) }
            start += count
        }
        return PublicListings(listings: found, skipped: skipped, capped: true)
    }

    public func publicItems(kindId: String) async throws -> [RemoteItem] {
        let body = try await call {
            try await api.data("GET", "/v1/items", query: [URLQueryItem(name: "kind", value: kindId)]).body
        }
        return try GymCatalogRows.items(from: GymCatalogRows.array(in: body, key: "rows")).rows
    }

    /// `<API_URL>/photos/shared/<name>`: public and cached, so loading it needs no session.
    public func publicPhotoURL(path: String) -> URL? {
        guard GymPhotoName.isValid(path) else { return nil }
        return api.baseURL.appending(path: "photos/shared/\(path.lowercased())")
    }

    // MARK: Writes

    public func findOrCreateGym(mapsPlaceId: String, name: String, address: String?, latitude: Double?,
                                longitude: Double?) async throws -> UUID {
        let place = Place(mapsPlaceId: mapsPlaceId, name: name, address: address, latitude: latitude,
                          longitude: longitude)
        let answer: IdAnswer = try await call { try await api.post("/v1/gyms/find-or-create", place) }
        return answer.id
    }

    public func share(_ request: ShareRequest) async throws -> ShareResult {
        let body = try await call {
            try await api.data("POST", "/v1/listings/share", body: SyncJSON.encoder.encode(ShareBody(request))).body
        }
        return try GymCatalogRows.shareResult(from: body, gymId: request.gymId)
    }

    public func confirm(listingId: UUID) async throws -> Int {
        let path = "/v1/listings/\(Self.text(listingId))/confirm"
        let answer: ConfirmAnswer = try await call { try await api.post(path, Empty()) }
        return answer.confirmCount
    }

    /// The server answers `{"status": "reported" | "own" | "already"}`; none of them is an error to the queue.
    public func report(targetType: GymTargetType, targetId: UUID, reason: ReportReason, note: String?) async throws {
        let body = ReportBody(targetType: targetType.rawValue, targetId: Self.text(targetId), reason: reason.rawValue,
                              note: note)
        _ = try await call { try await api.data("POST", "/v1/reports", body: SyncJSON.encoder.encode(body)) }
    }

    public func blockAuthor(targetType: GymTargetType, targetId: UUID) async throws {
        let body = Target(targetType: targetType.rawValue, targetId: Self.text(targetId))
        _ = try await call { try await api.data("POST", "/v1/blocks", body: SyncJSON.encoder.encode(body)) }
    }

    public func unblockAll() async throws -> Int {
        let body = try await call { try await api.data("DELETE", "/v1/blocks").body }
        return try Self.decode(Cleared.self, from: body, what: "unblock count").cleared
    }

    // MARK: Moderation

    public func isAdmin() async throws -> Bool {
        guard hasSession else { return false }
        let body = try await call { try await api.data("GET", "/v1/admin/me").body }
        return try Self.decode(AdminAnswer.self, from: body, what: "admin answer").admin
    }

    public func moderationQueue() async throws -> [ModerationEntry] {
        let body = try await call { try await api.data("GET", "/v1/admin/queue").body }
        return try GymCatalogRows.moderation(from: GymCatalogRows.array(in: body, key: "rows")).rows
    }

    public func moderate(targetType: GymTargetType, targetId: UUID, action: ModerationAction) async throws -> String? {
        let body = ModerateBody(targetType: targetType.rawValue, targetId: Self.text(targetId), action: action.rawValue)
        let answer = try await call {
            try await api.data("POST", "/v1/admin/moderate", body: SyncJSON.encoder.encode(body)).body
        }
        return try GymCatalogRows.moderatedPhoto(from: answer)
    }

    public func moderationPhotoDeleted(path: String) async throws {
        let body = PathBody(path: path.lowercased())
        _ = try await call {
            try await api.data("POST", "/v1/admin/photo-deleted", body: SyncJSON.encoder.encode(body))
        }
    }

    // MARK: Helpers

    enum UploadOutcome: Error { case alreadyThere }

    /// Every call's errors as `GymCatalogError`. A 409 `duplicate` is a photo an earlier try uploaded whose answer was
    /// lost; the upload treats it as done.
    func call<R>(_ body: () async throws -> R) async throws -> R {
        do {
            return try await body()
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch let failure as ApiError where failure.status == 409 && failure.code == "duplicate" {
            throw UploadOutcome.alreadyThere
        } catch {
            throw GymCatalogErrors.map(error, hasSession: hasSession)
        }
    }

    static func text(_ id: UUID) -> String { id.uuidString.lowercased() }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T {
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            throw GymCatalogError.rejected("unreadable \(what)")
        }
        return value
    }
}

// MARK: - Bodies and answers (server/src/gyms/share.ts, src/moderation/*.ts)

private struct Empty: Encodable {}

private struct Place: Encodable {
    let mapsPlaceId: String, name: String, address: String?, latitude: Double?, longitude: Double?

    enum CodingKeys: String, CodingKey { case name, address, latitude, longitude, mapsPlaceId = "maps_place_id" }
}

private struct ShareBody: Encodable {
    let listingId: String, gymId: String, kindId: String, brand: String?, model: String?, loads: ListingLoads
    let quantity: Int, notes: String?, photoPath: String?, forceNew: Bool

    init(_ request: ShareRequest) {
        listingId = ApiGymCatalogTransport.text(request.listingId)
        gymId = ApiGymCatalogTransport.text(request.gymId)
        kindId = request.kindId
        brand = request.brand
        model = request.model
        loads = request.loads
        quantity = request.quantity
        notes = request.notes
        photoPath = request.photoPath?.lowercased()
        forceNew = request.forceNew
    }

    enum CodingKeys: String, CodingKey {
        case brand, model, loads, quantity, notes
        case listingId = "listing_id", gymId = "gym_id", kindId = "kind_id", photoPath = "photo_path",
             forceNew = "force_new"
    }
}

private struct Target: Encodable {
    let targetType: String, targetId: String

    enum CodingKeys: String, CodingKey { case targetType = "target_type", targetId = "target_id" }
}

private struct ReportBody: Encodable {
    let targetType: String, targetId: String, reason: String, note: String?

    enum CodingKeys: String, CodingKey { case reason, note, targetType = "target_type", targetId = "target_id" }
}

private struct ModerateBody: Encodable {
    let targetType: String, targetId: String, action: String

    enum CodingKeys: String, CodingKey { case action, targetType = "target_type", targetId = "target_id" }
}

private struct PathBody: Encodable { let path: String }

private struct IdAnswer: Decodable { let id: UUID }

private struct ConfirmAnswer: Decodable {
    let confirmCount: Int

    enum CodingKeys: String, CodingKey { case confirmCount = "confirm_count" }
}

private struct Cleared: Decodable { let cleared: Int }

private struct AdminAnswer: Decodable { let admin: Bool }
