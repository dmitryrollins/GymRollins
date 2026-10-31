import Foundation
import GymCore
import GymData

/// A private row of `public.gym_equipment`. It points at its kind's generic item and keeps any brand and model in
/// `private_brand` and `private_model` (decision 11); the kind comes back through the embedded item.
public struct GymListingDTO: Codable, Sendable, Equatable, ServerStamped {
    public let id: UUID
    public let gymId: UUID
    /// What the pulled row's embedded item says; nil when it is missing.
    public let kindId: String?
    public let photoPath: String?
    public let loads: ListingLoads
    public let quantity: Int
    public let notes: String?
    public let brand: String?
    public let model: String?
    public let clientUpdatedAt: Date
    public let deletedAt: Date?
    public var updatedAt: Date?

    static let columns = "id,gym_id,item_id,photo_path,loads,quantity,notes,private_brand,private_model,"
        + "client_updated_at,deleted_at,updated_at,equipment_items(kind_id)"

    enum CodingKeys: String, CodingKey {
        case id, loads, quantity, notes, visibility
        case gymId = "gym_id", itemId = "item_id", photoPath = "photo_path", brand = "private_brand"
        case model = "private_model", clientUpdatedAt = "client_updated_at", deletedAt = "deleted_at"
        case updatedAt = "updated_at", item = "equipment_items"
    }

    private struct ItemRef: Decodable { let kindId: String
        enum CodingKeys: String, CodingKey { case kindId = "kind_id" }
    }

    public init(_ row: SyncRow<SyncedListing>) {
        let v = row.value
        id = v.id
        gymId = v.gymId
        kindId = v.kindId
        photoPath = v.remotePhotoPath?.lowercased()
        loads = v.loads
        quantity = v.quantity
        notes = v.notes
        brand = v.brand
        model = v.model
        clientUpdatedAt = row.clientUpdatedAt
        deletedAt = row.deletedAt
        updatedAt = row.serverUpdatedAt
    }

    /// A `loads` shape this version doesn't know reads as none instead of failing the whole page.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        gymId = try c.decode(UUID.self, forKey: .gymId)
        kindId = (try? c.decodeIfPresent(ItemRef.self, forKey: .item))??.kindId
        photoPath = try c.decodeIfPresent(String.self, forKey: .photoPath)
        loads = (try? c.decodeIfPresent(ListingLoads.self, forKey: .loads)) ?? ListingLoads.none
        quantity = try c.decode(Int.self, forKey: .quantity)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        brand = try c.decodeIfPresent(String.self, forKey: .brand)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        clientUpdatedAt = try c.decode(Date.self, forKey: .clientUpdatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// Nil when the row has no readable kind (the app can't place it).
    public func toDomain() -> SyncRow<SyncedListing>? {
        guard let kindId, !kindId.isEmpty else { return nil }
        let value = SyncedListing(id: id, gymId: gymId, kindId: kindId, brand: brand, model: model, loads: loads,
                                  quantity: quantity, notes: notes, photoFile: nil, remotePhotoPath: photoPath)
        return SyncRow(value: value, clientUpdatedAt: clientUpdatedAt, deletedAt: deletedAt, serverUpdatedAt: updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(gymId, forKey: .gymId)
        try c.encode(GymRepository.genericItemId(forKind: kindId ?? ""), forKey: .itemId)
        try c.encode("private", forKey: .visibility)
        try c.encode(photoPath, forKey: .photoPath)
        try c.encode(loads, forKey: .loads)
        try c.encode(quantity, forKey: .quantity)
        try c.encode(notes, forKey: .notes)
        try c.encode(brand, forKey: .brand)
        try c.encode(model, forKey: .model)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
    }
}
