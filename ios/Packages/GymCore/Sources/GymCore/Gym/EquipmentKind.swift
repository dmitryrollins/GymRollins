import Foundation

/// How a kind of equipment is grouped in the app (docs/specs/2026-10-30-gym-equipment-design.md §4).
public enum EquipmentCategory: String, Codable, Sendable, CaseIterable {
    case machine, cable
    case freeWeight = "free-weight"
    case bench, rack, cardio, accessory
}

/// How a kind carries load: a weight stack, plates, a fixed set of weights (dumbbells, kettlebells), the user's
/// bodyweight, or nothing (benches, balls).
public enum EquipmentLoadType: String, Codable, Sendable, CaseIterable {
    case stack
    case plateLoaded = "plate-loaded"
    case fixedSet = "fixed-set"
    case bodyweight, none

    /// The listing of such a kind decides an exercise's weight (`InventoryMatch.loadListingId`).
    public var bearsLoad: Bool { self == .stack || self == .plateLoaded || self == .fixedSet }
}

/// A curated kind of equipment from the bundled `equipment-kinds.json`. Users pick one when they add equipment;
/// exercises name kinds in their requirements (`ExerciseRequirements`).
public struct EquipmentKind: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let category: EquipmentCategory
    public let load: EquipmentLoadType

    public init(id: String, name: String, category: EquipmentCategory, load: EquipmentLoadType) {
        self.id = id
        self.name = name
        self.category = category
        self.load = load
    }

    /// A machine for the builder's spread rule (at most 2 exercises each): it bears load and isn't a free weight, so
    /// weight stacks, cables, plate-loaded machines and the Smith machine, but not dumbbells or a barbell.
    public var isMachine: Bool { category != .freeWeight && (load == .stack || load == .plateLoaded) }

    /// Decodes `equipment-kinds.json`: `{"version": 1, "kinds": [...]}`.
    public static func decodeList(_ data: Data) throws -> [EquipmentKind] {
        try JSONDecoder().decode(KindsFile.self, from: data).kinds
    }

    private struct KindsFile: Decodable {
        let version: Int
        let kinds: [EquipmentKind]
    }
}
