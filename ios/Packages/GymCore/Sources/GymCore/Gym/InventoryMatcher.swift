import Foundation

/// The listings an exercise uses at a gym: one per requirement group in group order, without duplicates (one
/// listing, such as a bench press station, can cover several groups).
public struct InventoryMatch: Sendable, Hashable {
    public let listingIds: [UUID]
    /// The listing that decides the weight: the first chosen listing whose kind bears load. Nil for bodyweight.
    public let loadListingId: UUID?

    public init(listingIds: [UUID], loadListingId: UUID?) {
        self.listingIds = listingIds
        self.loadListingId = loadListingId
    }

    public static let noEquipment = InventoryMatch(listingIds: [], loadListingId: nil)
}

/// Whether an exercise can be done at a gym.
public enum Availability: Sendable, Hashable {
    case available(InventoryMatch)
    /// The first requirement group that no listing covers (its kind ids).
    case missing([String])
    /// The exercise isn't in the requirements data.
    case unmapped
}

/// "Can this exercise be done at this gym, and on which listings?" (spec §5). Listings whose kind this app version
/// doesn't know are ignored.
public struct InventoryMatcher: Sendable {
    public let inventory: GymInventory
    private let requirements: ExerciseRequirements
    private let kinds: [String: EquipmentKind]
    /// Listings per kind id, best first (`better`).
    private let byKind: [String: [InventoryListing]]
    private let byId: [UUID: InventoryListing]

    public init(requirements: ExerciseRequirements, kinds: [EquipmentKind], inventory: GymInventory) {
        let kindsById = Dictionary(kinds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = inventory.listings.filter { kindsById[$0.kindId] != nil }
        self.inventory = inventory
        self.requirements = requirements
        self.kinds = kindsById
        self.byKind = Dictionary(grouping: known, by: \.kindId).mapValues { $0.sorted(by: Self.better) }
        self.byId = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// `excluded` listings are treated as absent; the builder uses it to move past a machine at its cap.
    public func availability(of exerciseId: String, excluding excluded: Set<UUID> = []) -> Availability {
        guard let groups = requirements.requirement(for: exerciseId) else { return .unmapped }
        var chosen: [InventoryListing] = []
        for group in groups where !chosen.contains(where: { group.contains($0.kindId) }) {
            let options = group.compactMap { kind in byKind[kind]?.first { !excluded.contains($0.id) } }
            guard let best = options.min(by: Self.better) else { return .missing(group) }
            chosen.append(best)
        }
        let load = chosen.first { kinds[$0.kindId]?.load.bearsLoad == true }
        return .available(InventoryMatch(listingIds: chosen.map(\.id), loadListingId: load?.id))
    }

    /// Every listing at the gym that could serve one of the exercise's requirement groups.
    func listingIds(serving exerciseId: String) -> Set<UUID> {
        let kindIds = (requirements.requirement(for: exerciseId) ?? []).joined()
        return Set(kindIds.flatMap { byKind[$0] ?? [] }.map(\.id))
    }

    /// The best score among the listings that could serve the same requirement group as `listing` for this exercise.
    /// Adding your own listing doesn't lower what the others have earned, so it can't push the exercise down the
    /// builder's ranking.
    func bestScore(sharingGroupWith listing: InventoryListing, for exerciseId: String) -> Int {
        let group = requirements.requirement(for: exerciseId)?.first { $0.contains(listing.kindId) } ?? [listing.kindId]
        return group.flatMap { byKind[$0] ?? [] }.map(\.score).max() ?? listing.score
    }

    public func listing(_ id: UUID) -> InventoryListing? { byId[id] }

    public func kind(_ id: String) -> EquipmentKind? { kinds[id] }

    /// Whether a requirement exists for the exercise and is empty (a no-equipment exercise).
    public func needsNoEquipment(_ exerciseId: String) -> Bool {
        requirements.requirement(for: exerciseId)?.isEmpty == true
    }

    /// The user's own listings first, then more confirmations, then the id (stable across runs).
    static func better(_ a: InventoryListing, _ b: InventoryListing) -> Bool {
        if a.isOwn != b.isOwn { return a.isOwn }
        if a.confirmCount != b.confirmCount { return a.confirmCount > b.confirmCount }
        return a.id.uuidString < b.id.uuidString
    }
}
