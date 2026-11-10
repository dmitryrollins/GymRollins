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
    /// Removes a photo the caller uploaded to `gym-photos`. Only the owner may; a name that is already gone is fine.
    func deleteSharedPhoto(path: String) async throws
    /// Removes every photo the caller owns in both gym buckets, listed or not, for account deletion. Stops at the first
    /// failure and throws it; an object that is already gone is not one.
    func deleteAllPhotos() async throws
    /// Clears the photo names from the caller's own listings, private and shared, so account deletion can remove the
    /// objects without leaving listings that name dead ones. Nothing is lost if it fails, and the account is untouched.
    func detachAllPhotos() async throws
    /// Reports a public gym or listing. The server also answers `own` (the reporter wrote it) and `already`; both
    /// count as sent. A target that is gone raises `GymCatalogError.unknownTarget`.
    func report(targetType: GymTargetType, targetId: UUID, reason: ReportReason, note: String?) async throws
    /// Hides everything the author of that gym or listing wrote. The phone never learns who the author is.
    func blockAuthor(targetType: GymTargetType, targetId: UUID) async throws
    /// Clears every block of the signed-in user and returns how many there were.
    func unblockAll() async throws -> Int
    /// Whether the signed-in user is a moderator. The server decides; this only spares non-admins a screen.
    func isAdmin() async throws -> Bool
    /// Everything flagged, most reported first. A non-admin gets `GymCatalogError.notAllowed`.
    func moderationQueue() async throws -> [ModerationEntry]
    /// Restores or removes a flagged gym or listing. Returns the photo the app must now delete through Storage.
    func moderate(targetType: GymTargetType, targetId: UUID, action: ModerationAction) async throws -> String?
    /// Tells the server the photo `moderate` returned is gone from Storage, so a removed listing's name can go. Only
    /// then does the listing leave the queue.
    func moderationPhotoDeleted(path: String) async throws
    func publicPhotoURL(path: String) -> URL?
}

/// What a report or a block names. Items aren't a target: everything visible about one comes through a listing.
public enum GymTargetType: String, Sendable, Codable { case gym, listing }

public enum ReportReason: String, Sendable, Codable, CaseIterable {
    case wrongInfo = "wrong-info", notHereAnymore = "not-here-anymore", duplicate
    case inappropriatePhoto = "inappropriate-photo", personInPhoto = "person-in-photo", spam, other
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
    /// The server refused this row for this account while the session is fine (as opposed to `.signedOut`).
    case notAllowed
    case gymFull
    /// Storage refused the upload: the daily photo limit, or a name a listing already uses.
    case photoRefused
    /// `share_listing` found the photo already used by another listing.
    case photoInUse
    /// `reports.note` failed its text check (control or invisible characters).
    case noteRefused
    /// The gym or listing is gone, or was removed: there is nothing left to report or block.
    case unknownTarget
    /// Someone created a new gym for this place after the removal, so the old one can't come back.
    case placeTaken
}
