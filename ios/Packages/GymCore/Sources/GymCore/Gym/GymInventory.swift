import Foundation

/// The loads a listing offers, stored as `gym_equipment.loads` (weights in kg).
public enum ListingLoads: Sendable, Hashable, Codable {
    /// A weight stack up to `maxKg`, in `stepKg` increments when known.
    case stack(maxKg: Double, stepKg: Double?)
    /// A fixed set of weights, e.g. kettlebells of 20 and 24 kg.
    case fixed(kg: [Double])
    /// Plates: rounding follows the profile's plate inventory, as it does today.
    case plates
    case none

    private enum CodingKeys: String, CodingKey { case type, maxKg, stepKg, kg }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "stack":
            self = .stack(maxKg: try c.decode(Double.self, forKey: .maxKg),
                          stepKg: try c.decodeIfPresent(Double.self, forKey: .stepKg))
        case "fixed": self = .fixed(kg: try c.decode([Double].self, forKey: .kg))
        case "plates": self = .plates
        case "none": self = .none
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown loads type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .stack(maxKg, stepKg):
            try c.encode("stack", forKey: .type)
            try c.encode(maxKg, forKey: .maxKg)
            try c.encodeIfPresent(stepKg, forKey: .stepKg)
        case let .fixed(kg):
            try c.encode("fixed", forKey: .type)
            try c.encode(kg, forKey: .kg)
        case .plates: try c.encode("plates", forKey: .type)
        case .none: try c.encode("none", forKey: .type)
        }
    }
}

/// One active listing at a gym, as the rules see it. The caller passes only active listings: the gym's shared ones
/// plus the user's own (synced or "This phone only").
public struct InventoryListing: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let kindId: String
    public let loads: ListingLoads
    public let confirmCount: Int
    /// Added by this user; the matcher prefers these and the builder ranks them like one more confirmation.
    public let isOwn: Bool

    public init(id: UUID, kindId: String, loads: ListingLoads = .none, confirmCount: Int = 0, isOwn: Bool = false) {
        self.id = id
        self.kindId = kindId
        self.loads = loads
        self.confirmCount = confirmCount
        self.isOwn = isOwn
    }

    /// The builder's ranking score: confirmations, plus one for the user's own listing.
    var score: Int { confirmCount + (isOwn ? 1 : 0) }
}

/// The equipment the rules may use at one gym.
public struct GymInventory: Sendable, Hashable {
    public let gymName: String
    public let listings: [InventoryListing]

    public init(gymName: String, listings: [InventoryListing]) {
        self.gymName = gymName
        self.listings = listings
    }
}
