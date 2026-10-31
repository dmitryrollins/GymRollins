import Foundation
import GymCore
import GymData

/// A private row of `public.gyms`. `visibility` is always `private` here: shared gyms come through the catalogue
/// transport, and the server fills `owner_id` from the session.
public struct GymDTO: Codable, Sendable, Equatable, ServerStamped {
    public let id: UUID
    public let name: String
    public let address: String?
    public let latitude: Double?
    public let longitude: Double?
    public let clientUpdatedAt: Date
    public let deletedAt: Date?
    public var updatedAt: Date?

    /// The columns a client may read; `select *` would ask for `owner_id`, which it can't.
    static let columns = "id,name,address,latitude,longitude,client_updated_at,deleted_at,updated_at"

    enum CodingKeys: String, CodingKey {
        case id, name, address, latitude, longitude, visibility
        case clientUpdatedAt = "client_updated_at", deletedAt = "deleted_at", updatedAt = "updated_at"
    }

    public init(_ row: SyncRow<SyncedGym>) {
        id = row.value.id
        name = row.value.name
        address = row.value.address
        latitude = row.value.latitude
        longitude = row.value.longitude
        clientUpdatedAt = row.clientUpdatedAt
        deletedAt = row.deletedAt
        updatedAt = row.serverUpdatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = GymCatalogRows.clip(try c.decode(String.self, forKey: .name), to: DomainLimits.gymNameMax) ?? ""
        address = GymCatalogRows.clip(try c.decodeIfPresent(String.self, forKey: .address), to: DomainLimits.gymAddressMax)
        latitude = GymCatalogRows.coordinate(try c.decodeIfPresent(Double.self, forKey: .latitude), within: 90)
        longitude = GymCatalogRows.coordinate(try c.decodeIfPresent(Double.self, forKey: .longitude), within: 180)
        clientUpdatedAt = try c.decode(Date.self, forKey: .clientUpdatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public func toDomain() -> SyncRow<SyncedGym> {
        SyncRow(value: SyncedGym(id: id, name: name, address: address, latitude: latitude, longitude: longitude),
                clientUpdatedAt: clientUpdatedAt, deletedAt: deletedAt, serverUpdatedAt: updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("private", forKey: .visibility)
        try c.encode(name, forKey: .name)
        try c.encode(address, forKey: .address)
        try c.encode(latitude, forKey: .latitude)
        try c.encode(longitude, forKey: .longitude)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
    }
}
