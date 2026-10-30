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
    public var createdAt: Date
    public var updatedAt: Date

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
    public var visibilityRaw: String
    public var uploadStateRaw: String
    public var uploadError: String?
    public var statusRaw: String
    public var confirmCount: Int
    public var isOwn: Bool
    public var remoteId: UUID?
    public var createdAt: Date
    public var updatedAt: Date

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
