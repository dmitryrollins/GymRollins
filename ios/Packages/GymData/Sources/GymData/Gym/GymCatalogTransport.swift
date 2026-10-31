import Foundation
import GymCore

/// The server side of the shared catalogue. Reads work with no account; writes need a signed-in user.
public protocol GymCatalogTransport: Sendable {
    func publicGym(mapsPlaceId: String) async throws -> RemoteGym?
    func publicListings(gymId: UUID) async throws -> PublicListings
    func publicItems(kindId: String) async throws -> [RemoteItem]
    func findOrCreateGym(mapsPlaceId: String, name: String, address: String?, latitude: Double?,
                         longitude: Double?) async throws -> UUID
    func share(_ request: ShareRequest) async throws -> ShareResult
    func confirm(listingId: UUID) async throws -> Int
    /// Uploads to `gym-photos/<name>`. A photo the caller already uploaded under that name counts as uploaded.
    func uploadSharedPhoto(_ data: Data, name: String) async throws -> String
    func publicPhotoURL(path: String) -> URL?
}

/// A gym's public listings as one read found them. A read that couldn't see everything says so: the cache must not
/// treat what it didn't see as removed.
public struct PublicListings: Sendable, Equatable {
    public let listings: [RemoteListing]
    /// Rows the server sent that this version couldn't read.
    public let skipped: Int
    /// The read stopped at its cap before reaching the end.
    public let capped: Bool

    public init(listings: [RemoteListing], skipped: Int = 0, capped: Bool = false) {
        self.listings = listings
        self.skipped = skipped
        self.capped = capped
    }

    public var isComplete: Bool { skipped == 0 && !capped }
}

public struct RemoteGym: Sendable, Equatable {
    public let id: UUID, name: String, address: String?, latitude: Double?, longitude: Double?, mapsPlaceId: String?

    public init(id: UUID, name: String, address: String?, latitude: Double?, longitude: Double?, mapsPlaceId: String?) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.mapsPlaceId = mapsPlaceId
    }
}

public struct RemoteItem: Sendable, Equatable {
    public let id: UUID, kindId: String, brand: String?, model: String?, gymCount: Int, photoPath: String?,
               photoListingId: UUID?

    public init(id: UUID, kindId: String, brand: String?, model: String?, gymCount: Int, photoPath: String? = nil,
                photoListingId: UUID? = nil) {
        self.id = id
        self.kindId = kindId
        self.brand = brand
        self.model = model
        self.gymCount = gymCount
        self.photoPath = photoPath
        self.photoListingId = photoListingId
    }
}

public struct RemoteListing: Sendable, Equatable, Codable {
    public let id: UUID, gymId: UUID, itemId: UUID, kindId: String, brand: String?, model: String?
    public let photoPath: String?, loads: ListingLoads?, quantity: Int, notes: String?
    public let status: String, confirmCount: Int, isMine: Bool, confirmedByMe: Bool

    // swiftlint:disable:next function_parameter_count
    public init(id: UUID, gymId: UUID, itemId: UUID, kindId: String, brand: String?, model: String?,
                photoPath: String?, loads: ListingLoads?, quantity: Int, notes: String?, status: String,
                confirmCount: Int, isMine: Bool, confirmedByMe: Bool) {
        self.id = id
        self.gymId = gymId
        self.itemId = itemId
        self.kindId = kindId
        self.brand = brand
        self.model = model
        self.photoPath = photoPath
        self.loads = loads
        self.quantity = quantity
        self.notes = notes
        self.status = status
        self.confirmCount = confirmCount
        self.isMine = isMine
        self.confirmedByMe = confirmedByMe
    }
}

public struct ShareRequest: Sendable, Equatable {
    public let listingId: UUID, gymId: UUID, kindId: String, brand: String?, model: String?
    public let loads: ListingLoads, quantity: Int, notes: String?, photoPath: String?, forceNew: Bool

    // swiftlint:disable:next function_parameter_count
    public init(listingId: UUID, gymId: UUID, kindId: String, brand: String?, model: String?, loads: ListingLoads,
                quantity: Int, notes: String?, photoPath: String?, forceNew: Bool) {
        self.listingId = listingId
        self.gymId = gymId
        self.kindId = kindId
        self.brand = brand
        self.model = model
        self.loads = loads
        self.quantity = quantity
        self.notes = notes
        self.photoPath = photoPath
        self.forceNew = forceNew
    }
}

public enum ShareResult: Sendable, Equatable { case created(UUID), duplicates([RemoteListing]) }

public enum GymCatalogError: Error, Equatable {
    case signedOut, dailyLimit, offline, gymNotShareable, photoMissing, rejected(String)
}
