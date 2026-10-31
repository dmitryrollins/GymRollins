import Foundation
import GymCore

/// Who a gym or listing is visible to (spec §5). Only `device` exists until plan 21.
public enum GymVisibility: String, Codable, Sendable, CaseIterable { case device, synced, shared }
public enum UploadState: String, Codable, Sendable { case local, queued, uploaded, failed, waitingForChoice }
public enum ListingStatus: String, Codable, Sendable { case active, flagged, removed, unsupported }

public struct Gym: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let address: String?
    public let latitude: Double?
    public let longitude: Double?
    /// `MKMapItem.identifier`; nil for a private gym, which can never be shared.
    public let mapsPlaceId: String?
    public let visibility: GymVisibility
    public let remoteId: UUID?
    public var isPrivate: Bool { mapsPlaceId == nil }
}

public struct EquipmentItem: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let kindId: String
    public let brand: String?
    public let model: String?
    public var isGeneric: Bool { brand == nil && model == nil }
}

public struct GymListing: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let gymId: UUID
    public let item: EquipmentItem
    public let loads: ListingLoads
    public let quantity: Int
    public let notes: String?
    /// File name inside `GymPhotoStore`; nil when the user skipped the photo.
    public let photoFile: String?
    public let visibility: GymVisibility
    public let uploadState: UploadState
    public let uploadError: String?
    public let status: ListingStatus
    public let confirmCount: Int
    public let isOwn: Bool
    public let remoteId: UUID?
    public let createdAt: Date
}

public struct NewListing: Sendable {
    public let gymId: UUID
    public let kindId: String
    public let brand: String?
    public let model: String?
    public let loads: ListingLoads
    public let quantity: Int
    public let notes: String?
    public let photoFile: String?

    public init(gymId: UUID, kindId: String, brand: String? = nil, model: String? = nil, loads: ListingLoads = .none,
                quantity: Int = 1, notes: String? = nil, photoFile: String? = nil) {
        self.gymId = gymId
        self.kindId = kindId
        self.brand = brand
        self.model = model
        self.loads = loads
        self.quantity = quantity
        self.notes = notes
        self.photoFile = photoFile
    }
}

/// A known item of a kind and how many of My gyms list it (Step 3 of adding equipment).
public struct CatalogueItem: Sendable, Hashable, Identifiable {
    public let item: EquipmentItem
    public let gymCount: Int
    public var id: UUID { item.id }
}
