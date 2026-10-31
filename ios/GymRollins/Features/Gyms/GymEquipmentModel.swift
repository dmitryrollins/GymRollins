import Foundation
import GymCore
import GymData

/// What the gym equipment screen shows, worked out once per load so the view only draws it (spec §6).
struct GymEquipmentModel: Equatable {
    /// The status chip on a tile. My own listing a moderator flagged reads "Under review". A share that is waiting,
    /// stuck or undecided shows before the confirm count.
    enum ListingBadge: Equatable {
        case onlyMe, synced, waiting, failed, needsChoice, confirmed(Int), underReview

        var text: String {
            switch self {
            case .onlyMe: "Only me"
            case .synced: "Synced"
            case .waiting: "Waiting to upload"
            case .failed: "Couldn't upload"
            case .needsChoice: "Needs a choice"
            case let .confirmed(count): "\u{2713} \(count)"
            case .underReview: "Under review"
            }
        }

        var kind: Badge.Kind {
            switch self {
            case .onlyMe, .synced, .waiting, .needsChoice: .neutral
            case .confirmed: .success
            case .failed, .underReview: .record
            }
        }

        init?(_ listing: GymListing) {
            if listing.status == .flagged { self = .underReview }
            else if listing.uploadState == .failed { self = .failed }
            else if listing.uploadState == .queued { self = .waiting }
            else if listing.uploadState == .waitingForChoice { self = .needsChoice }
            else if listing.confirmCount > 0 { self = .confirmed(listing.confirmCount) }
            else if listing.visibility == .device { self = .onlyMe }
            else if listing.visibility == .synced { self = .synced }
            else { return nil }
        }
    }

    /// One muscle chip's count of listings that could serve an equipment exercise for it.
    struct Coverage: Identifiable, Equatable {
        static let thinBelow = 3
        let muscle: BuildMuscle
        let count: Int
        var id: String { muscle.rawValue }
        var isThin: Bool { count < Self.thinBelow }
        var text: String { "\(muscle.rawValue.capitalized) \(count)" }
    }

    struct Tile: Identifiable, Equatable {
        let listing: GymListing
        /// Nil when this app has no such kind (a newer app made the listing).
        let kind: EquipmentKind?
        let title: String
        let brandAndModel: String?
        let loadsText: String?
        let badge: ListingBadge?
        let quantityText: String?
        var id: UUID { listing.id }
        var isKnown: Bool { kind != nil }
    }

    struct Section: Identifiable, Equatable {
        let title: String
        let tiles: [Tile]
        var id: String { title }
    }

    static let unknownKindTitle = "Update the app to use this item"
    static let unknownSectionTitle = "Other"
    private static let categoryOrder: [(EquipmentCategory, String)] = [
        (.machine, "Machines"), (.cable, "Cables"), (.freeWeight, "Free weights"), (.bench, "Benches"),
        (.rack, "Racks"), (.cardio, "Cardio"), (.accessory, "Accessories"),
    ]

    let gym: Gym
    let sections: [Section]
    let coverage: [Coverage]
    let itemCount: Int

    var isEmpty: Bool { itemCount == 0 }

    /// "Home \u{00B7} 3 items": the address when there is one, then the count.
    var subtitle: String {
        let count = itemCount == 1 ? "1 item" : "\(itemCount) items"
        return [gym.address, count].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    init(gym: Gym, listings: [GymListing], catalog: GymEquipmentCatalog, unit: WeightUnit, coverage: [Coverage]) {
        self.gym = gym
        self.coverage = coverage
        self.itemCount = listings.count
        let tiles = listings.map { Self.tile($0, catalog: catalog, unit: unit) }
        var sections = Self.categoryOrder.compactMap { category, title -> Section? in
            let members = tiles.filter { $0.kind?.category == category }
            return members.isEmpty ? nil : Section(title: title, tiles: members)
        }
        let unknown = tiles.filter { !$0.isKnown }
        if !unknown.isEmpty { sections.append(Section(title: Self.unknownSectionTitle, tiles: unknown)) }
        self.sections = sections
    }

    private static func tile(_ listing: GymListing, catalog: GymEquipmentCatalog, unit: WeightUnit) -> Tile {
        // A row a newer app wrote has kinds or loads this app can't read: it is listed, but not used.
        let kind = listing.status == .unsupported ? nil : catalog.kind(listing.item.kindId)
        let brandAndModel = [listing.item.brand, listing.item.model].compactMap { $0 }.joined(separator: " ")
        return Tile(listing: listing, kind: kind, title: kind?.name ?? unknownKindTitle,
                    brandAndModel: kind == nil || brandAndModel.isEmpty ? nil : brandAndModel,
                    loadsText: kind == nil ? nil : ListingLoadsText.text(listing.loads, unit: unit),
                    badge: ListingBadge(listing), quantityText: listing.quantity > 1 ? "\u{00D7}\(listing.quantity)" : nil)
    }

    /// Runs a full candidate pass per chip, so callers off the main actor should call this, not the main one.
    /// Empty history: coverage is what the gym can serve, not what was trained lately.
    nonisolated static func coverage(matcher: InventoryMatcher, exercises: [Exercise], asOf date: Date) -> [Coverage] {
        let builder = WorkoutBuilder(matcher: matcher, exercises: exercises, history: [])
        return BuildMuscle.allCases.map { Coverage(muscle: $0, count: builder.itemCount(for: $0, asOf: date)) }
    }
}
