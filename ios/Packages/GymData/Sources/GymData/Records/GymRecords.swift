import Foundation
import GymCore
import SwiftData

/// A gym the user trains at: picked from Maps, or private (no `mapsPlaceId`). Local-only until plan 21.
@Model
public final class GymRecord {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var address: String?
    public var latitude: Double?
    public var longitude: Double?
    public var mapsPlaceId: String?
    public var visibilityRaw: String
    public var remoteId: UUID?
    /// When the gym's public listings were last downloaded; nil until the first refresh.
    public var catalogRefreshedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    /// Sync bookkeeping, used only while `visibilityRaw` is `synced`.
    public var serverUpdatedAt: Date?
    public var dirty: Bool = false
    public var deletedAt: Date?
    /// Set when a sign-out turned this synced gym into a "This phone only" one: the account whose server row this
    /// id still names. Signing back in as that account gives the row back; any other account gets a new id.
    public var demotedOwnerId: UUID?
    /// Whether the row held an edit the server hadn't seen when it was demoted.
    public var demotedDirty: Bool = false

    public init(id: UUID = UUID(), name: String, address: String?, latitude: Double? = nil, longitude: Double? = nil,
                mapsPlaceId: String? = nil, now: Date) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.mapsPlaceId = mapsPlaceId
        self.visibilityRaw = GymVisibility.device.rawValue
        self.createdAt = now
        self.updatedAt = now
    }
}

/// A kind of equipment with an optional brand and model. The brandless, modelless row of a kind is its generic item.
@Model
public final class EquipmentItemRecord {
    @Attribute(.unique) public var id: UUID
    public var kindId: String
    public var brand: String?
    public var model: String?
    /// A picture of this item from another gym's listing, loaded by URL. Never uploaded, never a listing's own photo.
    public var catalogPhotoPath: String?
    public var catalogPhotoListingId: UUID?
    public var createdAt: Date

    public init(id: UUID = UUID(), kindId: String, brand: String?, model: String?, now: Date) {
        self.id = id
        self.kindId = kindId
        self.brand = brand
        self.model = model
        self.createdAt = now
    }
}

/// One item at one gym. Removal is a hard delete; `status` only matters for server rows (plan 21).
@Model
public final class GymListingRecord {
    @Attribute(.unique) public var id: UUID
    public var gymId: UUID
    public var itemId: UUID
    public var kindId: String
    /// `ListingLoads` as JSON, so a newer app's loads type can never break reading.
    public var loadsData: Data
    public var quantity: Int
    public var notes: String?
    public var photoFile: String?
    /// Name of the picture in the `gym-photos` bucket, set as soon as the upload succeeds.
    public var remotePhotoPath: String?
    public var confirmedByMe: Bool = false
    /// The duplicates `share_listing` returned, as JSON, while the upload is `.waitingForChoice`.
    public var duplicatesData: Data?
    public var visibilityRaw: String
    public var uploadStateRaw: String
    public var uploadError: String?
    public var statusRaw: String
    public var confirmCount: Int
    public var isOwn: Bool
    public var remoteId: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    /// Sync bookkeeping, used only while `visibilityRaw` is `synced`.
    public var serverUpdatedAt: Date?
    public var dirty: Bool = false
    public var deletedAt: Date?
    /// Set when a sign-out turned this synced or queued listing into a "This phone only" one: the account whose
    /// server row this id may still name. The same account signing back in gets a synced listing's edit pushed;
    /// any other account gets a new id.
    public var demotedOwnerId: UUID?
    /// Whether the row held an edit the server hadn't seen when it was demoted.
    public var demotedDirty: Bool = false

    public init(id: UUID = UUID(), gymId: UUID, itemId: UUID, kindId: String, loadsData: Data, quantity: Int,
                notes: String?, photoFile: String?, now: Date) {
        self.id = id
        self.gymId = gymId
        self.itemId = itemId
        self.kindId = kindId
        self.loadsData = loadsData
        self.quantity = quantity
        self.notes = notes
        self.photoFile = photoFile
        self.visibilityRaw = GymVisibility.device.rawValue
        self.uploadStateRaw = UploadState.local.rawValue
        self.statusRaw = ListingStatus.active.rawValue
        self.confirmCount = 0
        self.isOwn = true
        self.createdAt = now
        self.updatedAt = now
    }
}
