import Foundation
import GymCore
import SwiftData

/// Gyms, the equipment items they list and each gym's listings. Everything stays on the phone until plan 21.
@MainActor
public final class GymRepository {
    public static let maxNameLength = 120
    public static let maxAddressLength = 300
    public static let maxQuantity = 50
    public static let maxNotesLength = 280
    public static let maxBrandLength = 60
    public static let maxModelLength = 80
    public static let maxStackKg = 1000.0
    public static let maxFixedWeights = 60
    public static let maxFixedKg = 500.0

    /// Namespace for the generic item of each kind, so every install derives the same id.
    static let genericItemNamespace = UUID(uuidString: "6b1f3c2e-8d4a-5e17-9a60-2f4c7d9b1e35")!

    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    // MARK: - Gyms

    public func gyms() throws -> [Gym] {
        try context.fetch(FetchDescriptor<GymRecord>()).map(Self.gym)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func gym(_ id: UUID) throws -> Gym? { try gymRecord(id).map(Self.gym) }

    @discardableResult
    public func addPrivateGym(name: String, address: String?) throws -> Gym {
        let (name, address) = try Self.validGym(name: name, address: address)
        let record = GymRecord(name: name, address: address, now: now())
        context.insert(record)
        try context.save()
        return Self.gym(record)
    }

    /// Adds a gym picked from Maps, or returns the one already stored for that place.
    @discardableResult
    public func addMapsGym(placeId: String, name: String, address: String?, latitude: Double,
                           longitude: Double) throws -> Gym {
        if let existing = try context.fetch(FetchDescriptor<GymRecord>(
            predicate: #Predicate { $0.mapsPlaceId == placeId })).first {
            return Self.gym(existing)
        }
        guard !placeId.isEmpty, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw GymDataError.invalidInput("Unknown place.")
        }
        let (name, address) = try Self.validGym(name: name, address: address)
        let record = GymRecord(name: name, address: address, latitude: latitude, longitude: longitude,
                               mapsPlaceId: placeId, now: now())
        context.insert(record)
        try context.save()
        return Self.gym(record)
    }

    /// Renames a private gym. A Maps gym's name and address come from Maps and stay as they are.
    @discardableResult
    public func updateGym(_ id: UUID, name: String, address: String?) throws -> Gym {
        guard let record = try gymRecord(id) else { throw GymDataError.invalidInput("Unknown gym.") }
        guard record.mapsPlaceId == nil else {
            throw GymDataError.invalidInput("A gym from Maps can't be renamed.")
        }
        let (name, address) = try Self.validGym(name: name, address: address)
        record.name = name
        record.address = address
        record.updatedAt = now()
        try context.save()
        return Self.gym(record)
    }

    /// Removes the gym and its listings (the items stay for other gyms) and returns the photo files to delete.
    public func deleteGym(_ id: UUID) throws -> [String] {
        let rows = try context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.gymId == id }))
        let photos = rows.compactMap(\.photoFile)
        rows.forEach(context.delete)
        if let record = try gymRecord(id) { context.delete(record) }
        try context.save()
        return photos
    }

    /// How many active listings each gym has.
    public func itemCounts() throws -> [UUID: Int] {
        try activeRecords().reduce(into: [:]) { counts, record in counts[record.gymId, default: 0] += 1 }
    }

    // MARK: - Listings

    public func listings(gymId: UUID) throws -> [GymListing] {
        let rows = try context.fetch(FetchDescriptor<GymListingRecord>(
            predicate: #Predicate { $0.gymId == gymId }, sortBy: [SortDescriptor(\.createdAt)]))
        return try rows.filter { $0.statusRaw == ListingStatus.active.rawValue }.map(listing)
    }

    public func listing(_ id: UUID) throws -> GymListing? { try listingRecord(id).map(listing) }

    @discardableResult
    public func addListing(_ new: NewListing) throws -> GymListing {
        guard try gymRecord(new.gymId) != nil else { throw GymDataError.invalidInput("Unknown gym.") }
        guard !new.kindId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GymDataError.invalidInput("Pick a kind of equipment.")
        }
        let brand = Self.clean(new.brand), model = Self.clean(new.model)
        try Self.validate(brand: brand, model: model)
        let notes = Self.clean(new.notes)
        try Self.validate(loads: new.loads, quantity: new.quantity, notes: notes)
        let item = try itemRecord(kindId: new.kindId, brand: brand, model: model)
        let record = GymListingRecord(gymId: new.gymId, itemId: item.id, kindId: new.kindId,
                                      loadsData: try JSONEncoder().encode(new.loads), quantity: new.quantity,
                                      notes: notes, photoFile: new.photoFile, now: now())
        context.insert(record)
        try context.save()
        return try listing(record)
    }

    @discardableResult
    public func updateListing(_ id: UUID, loads: ListingLoads, quantity: Int, notes: String?) throws -> GymListing {
        guard let record = try listingRecord(id) else { throw GymDataError.invalidInput("Unknown listing.") }
        let notes = Self.clean(notes)
        try Self.validate(loads: loads, quantity: quantity, notes: notes)
        record.loadsData = try JSONEncoder().encode(loads)
        record.quantity = quantity
        record.notes = notes
        record.updatedAt = now()
        try context.save()
        return try listing(record)
    }

    /// Deletes the listing and returns its photo file, if it had one, so the caller can delete the file.
    @discardableResult
    public func removeListing(_ id: UUID) throws -> String? {
        guard let record = try listingRecord(id) else { throw GymDataError.invalidInput("Unknown listing.") }
        let photo = record.photoFile
        context.delete(record)
        try context.save()
        return photo
    }

    // MARK: - Catalogue and inventory

    /// Branded items of a kind that at least one of My gyms lists, most widely listed first.
    public func catalogueItems(kindId: String) throws -> [CatalogueItem] {
        let items = try context.fetch(FetchDescriptor<EquipmentItemRecord>(predicate: #Predicate { $0.kindId == kindId }))
            .filter { $0.brand != nil || $0.model != nil }
        let gymsByItem = try activeRecords().filter { $0.kindId == kindId }
            .reduce(into: [UUID: Set<UUID>]()) { result, row in result[row.itemId, default: []].insert(row.gymId) }
        return items.compactMap { record in
            gymsByItem[record.id].map { CatalogueItem(item: Self.item(record), gymCount: $0.count) }
        }
        .sorted {
            if $0.gymCount != $1.gymCount { return $0.gymCount > $1.gymCount }
            return ($0.item.brand ?? "", $0.item.model ?? "") < ($1.item.brand ?? "", $1.item.model ?? "")
        }
    }

    /// What the rules from plan 19 may use at this gym.
    public func inventory(gymId: UUID) throws -> GymInventory {
        guard let gym = try gymRecord(gymId) else { throw GymDataError.invalidInput("Unknown gym.") }
        let listings = try listings(gymId: gymId).map {
            InventoryListing(id: $0.id, kindId: $0.item.kindId, loads: $0.loads, confirmCount: $0.confirmCount,
                             isOwn: $0.isOwn)
        }
        return GymInventory(gymName: gym.name, listings: listings)
    }

    // MARK: - Helpers

    private func gymRecord(_ id: UUID) throws -> GymRecord? {
        try context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func listingRecord(_ id: UUID) throws -> GymListingRecord? {
        try context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func activeRecords() throws -> [GymListingRecord] {
        try context.fetch(FetchDescriptor<GymListingRecord>()).filter { $0.statusRaw == ListingStatus.active.rawValue }
    }

    /// The item for a kind, brand and model (matched ignoring case), created on first use.
    private func itemRecord(kindId: String, brand: String?, model: String?) throws -> EquipmentItemRecord {
        let candidates = try context.fetch(FetchDescriptor<EquipmentItemRecord>(predicate: #Predicate { $0.kindId == kindId }))
        if let match = candidates.first(where: {
            Self.same($0.brand, brand) && Self.same($0.model, model)
        }) { return match }
        let id = brand == nil && model == nil
            ? StableUUID.make(namespace: Self.genericItemNamespace, name: kindId) : UUID()
        let record = EquipmentItemRecord(id: id, kindId: kindId, brand: brand, model: model, now: now())
        context.insert(record)
        return record
    }

    private func listing(_ record: GymListingRecord) throws -> GymListing {
        let itemId = record.itemId
        guard let item = try context.fetch(FetchDescriptor<EquipmentItemRecord>(
            predicate: #Predicate { $0.id == itemId })).first else {
            throw GymDataError.invalidInput("A listing lost its equipment item.")
        }
        return GymListing(
            id: record.id, gymId: record.gymId, item: Self.item(item),
            loads: (try? JSONDecoder().decode(ListingLoads.self, from: record.loadsData)) ?? ListingLoads.none,
            quantity: record.quantity, notes: record.notes, photoFile: record.photoFile,
            visibility: GymVisibility(rawValue: record.visibilityRaw) ?? .device,
            uploadState: UploadState(rawValue: record.uploadStateRaw) ?? .local, uploadError: record.uploadError,
            status: ListingStatus(rawValue: record.statusRaw) ?? .active, confirmCount: record.confirmCount,
            isOwn: record.isOwn, remoteId: record.remoteId, createdAt: record.createdAt)
    }

    private static func gym(_ r: GymRecord) -> Gym {
        Gym(id: r.id, name: r.name, address: r.address, latitude: r.latitude, longitude: r.longitude,
            mapsPlaceId: r.mapsPlaceId, visibility: GymVisibility(rawValue: r.visibilityRaw) ?? .device,
            remoteId: r.remoteId)
    }

    private static func item(_ r: EquipmentItemRecord) -> EquipmentItem {
        EquipmentItem(id: r.id, kindId: r.kindId, brand: r.brand, model: r.model)
    }

    private static func same(_ a: String?, _ b: String?) -> Bool {
        (a ?? "").caseInsensitiveCompare(b ?? "") == .orderedSame
    }

    /// Trimmed text, or nil when nothing is left.
    private static func clean(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Validation

    private static func validGym(name: String, address: String?) throws -> (String, String?) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...maxNameLength).contains(name.count) else {
            throw GymDataError.invalidInput("Give the gym a name of up to \(maxNameLength) characters.")
        }
        let address = clean(address)
        if let address, address.count > maxAddressLength {
            throw GymDataError.invalidInput("The address can be up to \(maxAddressLength) characters.")
        }
        return (name, address)
    }

    private static func validate(brand: String?, model: String?) throws {
        if let brand, brand.count > maxBrandLength {
            throw GymDataError.invalidInput("The brand can be up to \(maxBrandLength) characters.")
        }
        if let model, model.count > maxModelLength {
            throw GymDataError.invalidInput("The model can be up to \(maxModelLength) characters.")
        }
    }

    private static func validate(loads: ListingLoads, quantity: Int, notes: String?) throws {
        guard (1...maxQuantity).contains(quantity) else {
            throw GymDataError.invalidInput("The quantity must be between 1 and \(maxQuantity).")
        }
        if let notes, notes.count > maxNotesLength {
            throw GymDataError.invalidInput("The note can be up to \(maxNotesLength) characters.")
        }
        switch loads {
        case let .stack(maxKg, stepKg):
            guard maxKg > 0, maxKg <= maxStackKg else {
                throw GymDataError.invalidInput("The stack's top weight must be between 0 and \(Int(maxStackKg)) kg.")
            }
            if let stepKg, stepKg <= 0 || stepKg > maxKg {
                throw GymDataError.invalidInput("The step must be above 0 and no more than the top weight.")
            }
        case let .fixed(kg):
            guard (1...maxFixedWeights).contains(kg.count), kg.allSatisfy({ $0 > 0 && $0 <= maxFixedKg }) else {
                throw GymDataError.invalidInput("List between 1 and \(maxFixedWeights) weights, each up to \(Int(maxFixedKg)) kg.")
            }
        case .plates, .none: break
        }
    }
}
