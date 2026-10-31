import Foundation
import GymCore
import GymData
import Supabase

/// `GymCatalogTransport` over the shared-catalogue views, functions and Storage bucket. Reads work with the anon key;
/// writes need a session. Views are read with explicit column lists, and every UUID sent as text is lowercase because
/// the policies and `share_listing` compare against lowercase text.
public struct SupabaseGymCatalogTransport: GymCatalogTransport {
    static let pageSize = 500
    /// A gym holds at most `DomainLimits.gymActiveListingsMax` (300) active listings, so one page covers it; two pages
    /// is the most this reads, and a gym past that is reported as partial instead of looped on.
    static let maxPages = 2
    static let bucket = "gym-photos"
    private static let gymColumns = "id,name,address,latitude,longitude,maps_place_id,status"
    private static let itemColumns = "id,kind_id,brand,model,photo_path,photo_listing_id,gym_count"
    private static let listingColumns = "id,gym_id,item_id,kind_id,brand,model,photo_path,loads,quantity,notes,status,"
        + "confirm_count,is_mine,confirmed_by_me"

    private let client: SupabaseClient

    public init(client: SupabaseClient) { self.client = client }

    // MARK: Reads

    public func publicGym(mapsPlaceId: String) async throws -> RemoteGym? {
        let data = try await call {
            try await client.from("public_gyms").select(Self.gymColumns)
                .eq("maps_place_id", value: mapsPlaceId).neq("status", value: "removed")
                .order("created_at", ascending: false).limit(1).execute().data
        }
        return try GymCatalogRows.gyms(from: data).rows.first
    }

    public func publicListings(gymId: UUID) async throws -> PublicListings {
        try await Self.readListings { start in
            try await call {
                try await client.from("public_gym_equipment").select(Self.listingColumns)
                    .eq("gym_id", value: Self.text(gymId)).order("created_at").order("id")
                    .range(from: start, to: start + Self.pageSize - 1).execute().data
            }
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
        let data = try await call {
            try await client.from("public_equipment_items").select(Self.itemColumns)
                .eq("kind_id", value: kindId).eq("status", value: "active").order("id").execute().data
        }
        return try GymCatalogRows.items(from: data).rows
    }

    public func publicPhotoURL(path: String) -> URL? {
        try? client.storage.from(Self.bucket).getPublicURL(path: path.lowercased())
    }

    // MARK: Writes

    public func findOrCreateGym(mapsPlaceId: String, name: String, address: String?, latitude: Double?,
                                longitude: Double?) async throws -> UUID {
        let params: [String: AnyJSON] = [
            "p_maps_place_id": .string(mapsPlaceId), "p_name": .string(name), "p_address": Self.json(address),
            "p_latitude": Self.json(latitude), "p_longitude": Self.json(longitude),
        ]
        let data = try await call { try await client.rpc("find_or_create_gym", params: params).execute().data }
        guard let id = try? JSONDecoder().decode(UUID.self, from: data) else {
            throw GymCatalogError.rejected("unreadable gym id")
        }
        return id
    }

    public func share(_ request: ShareRequest) async throws -> ShareResult {
        let params: [String: AnyJSON] = [
            "p_listing_id": .string(Self.text(request.listingId)), "p_gym_id": .string(Self.text(request.gymId)),
            "p_kind_id": .string(request.kindId), "p_brand": Self.json(request.brand),
            "p_model": Self.json(request.model), "p_loads": try SupabaseTransport.anyJSON(request.loads),
            "p_quantity": .integer(request.quantity), "p_notes": Self.json(request.notes),
            "p_photo_path": Self.json(request.photoPath?.lowercased()), "p_force_new": .bool(request.forceNew),
        ]
        let data = try await call { try await client.rpc("share_listing", params: params).execute().data }
        return try GymCatalogRows.shareResult(from: data, gymId: request.gymId)
    }

    public func confirm(listingId: UUID) async throws -> Int {
        let params: [String: AnyJSON] = ["p_listing_id": .string(Self.text(listingId))]
        let data = try await call { try await client.rpc("confirm_listing", params: params).execute().data }
        guard let count = try? JSONDecoder().decode(Int.self, from: data) else {
            throw GymCatalogError.rejected("unreadable confirm count")
        }
        return count
    }

    public func uploadSharedPhoto(_ data: Data, name: String) async throws -> String {
        guard client.auth.currentSession != nil else { throw GymCatalogError.signedOut }
        let stored = name.lowercased()
        do {
            _ = try await call {
                try await client.storage.from(Self.bucket).upload(
                    stored, data: data, options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg",
                                                             upsert: false))
            }
        } catch UploadOutcome.alreadyThere {
            // The same photo, uploaded by an earlier try whose answer was lost.
        }
        return stored
    }

    // MARK: Helpers

    private enum UploadOutcome: Error { case alreadyThere }

    private func call<R>(_ body: () async throws -> R) async throws -> R {
        do {
            return try await body()
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch let failure as StorageError where GymCatalogErrors.isDuplicateUpload(failure) {
            throw UploadOutcome.alreadyThere
        } catch {
            throw GymCatalogErrors.map(error)
        }
    }

    private static func text(_ id: UUID) -> String { id.uuidString.lowercased() }

    private static func json(_ value: String?) -> AnyJSON { value.map(AnyJSON.string) ?? .null }

    private static func json(_ value: Double?) -> AnyJSON { value.map(AnyJSON.double) ?? .null }
}
