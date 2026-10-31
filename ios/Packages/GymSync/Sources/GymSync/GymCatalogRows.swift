import Foundation
import GymCore
import GymData
import os

/// Decodes the catalogue's views and function results. Rows are read one at a time so one bad row never hides the
/// rest of a gym (plan 21, decision 13); a row with a `loads` shape this version doesn't know comes back with none.
enum GymCatalogRows {
    private static let log = Logger(subsystem: "com.rollins.gymrollins", category: "gym-catalog")

    /// What one page decoded to, and how many of its rows could not be read.
    struct Decoded<Row> {
        let rows: [Row]
        let skipped: Int
    }

    static func listings(from data: Data) throws -> Decoded<RemoteListing> {
        let page = try rows(ListingRow.self, from: data)
        return Decoded(rows: page.rows.map { $0.listing(gymId: nil) }, skipped: page.skipped)
    }

    static func gyms(from data: Data) throws -> Decoded<RemoteGym> {
        let page = try rows(GymRow.self, from: data)
        return Decoded(rows: page.rows.map(\.gym), skipped: page.skipped)
    }

    static func items(from data: Data) throws -> Decoded<RemoteItem> {
        let page = try rows(ItemRow.self, from: data)
        return Decoded(rows: page.rows.map(\.item), skipped: page.skipped)
    }

    static func moderation(from data: Data) throws -> Decoded<ModerationEntry> {
        let page = try rows(ModerationRow.self, from: data)
        return Decoded(rows: page.rows.map(\.entry), skipped: page.skipped)
    }

    /// The photo `moderate_content` hands back for the app to delete; nil when the target had none.
    static func moderatedPhoto(from data: Data) throws -> String? {
        guard let answer = try? JSONDecoder().decode(ModerateAnswer.self, from: data) else {
            throw GymCatalogError.rejected("unreadable moderation answer")
        }
        return photoName(answer.photoPath)
    }

    /// How many rows the server sent, readable or not (a page is full when this reaches the page size).
    static func rawCount(of data: Data) -> Int {
        ((try? JSONSerialization.jsonObject(with: data)) as? [Any])?.count ?? 0
    }

    static func shareResult(from data: Data, gymId: UUID) throws -> ShareResult {
        guard let answer = try? JSONDecoder().decode(ShareAnswer.self, from: data) else {
            throw GymCatalogError.rejected("unreadable share answer")
        }
        switch answer.status {
        case "created":
            guard let id = answer.listingId else { throw GymCatalogError.rejected("share answer without a listing") }
            return .created(id)
        case "duplicates":
            let found = try rows(ListingRow.self, from: try JSONEncoder().encode(answer.listings))
            return .duplicates(found.rows.map { $0.listing(gymId: gymId) })
        default:
            throw GymCatalogError.rejected("unknown share status")
        }
    }

    private static func rows<T: Decodable>(_ type: T.Type, from data: Data) throws -> Decoded<T> {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            throw GymCatalogError.rejected("unreadable response")
        }
        var skipped = 0
        let found: [T] = array.compactMap { element in
            do {
                guard JSONSerialization.isValidJSONObject(element) else { throw RowError.notAnObject }
                return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: element))
            } catch {
                skipped += 1
                log.error("Skipped an unreadable \(String(describing: T.self)) row: \(error.localizedDescription)")
                return nil
            }
        }
        return Decoded(rows: found, skipped: skipped)
    }

    private enum RowError: Error { case notAnObject }

    // MARK: What the server sends is checked
    // Another app version or a bad client may have written these, and some end up in URLs or in the rules.

    /// Text cut to a limit, so a row can't carry kilobytes into the cache.
    static func clip(_ text: String?, to limit: Int) -> String? {
        guard let text, text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    /// A photo name that is a UUID and `.jpg`, else nil: a name like `../x` would redirect the request, which carries
    /// the user's token for the private bucket.
    static func photoName(_ name: String?) -> String? {
        name.flatMap { GymPhotoName.isValid($0) ? $0 : nil }
    }

    /// Loads outside the limits read as unreadable, which makes the listing unsupported like any unknown shape.
    static func inLimits(_ loads: ListingLoads) -> ListingLoads? {
        loads.isWithinLimits ? loads : nil
    }

    static func coordinate(_ value: Double?, within limit: Double) -> Double? {
        guard let value, value.isFinite, abs(value) <= limit else { return nil }
        return value
    }
}

private struct GymRow: Decodable {
    let id: UUID, name: String, address: String?, latitude: Double?, longitude: Double?, mapsPlaceId: String?

    enum CodingKeys: String, CodingKey {
        case id, name, address, latitude, longitude, mapsPlaceId = "maps_place_id"
    }

    var gym: RemoteGym {
        RemoteGym(id: id, name: GymCatalogRows.clip(name, to: DomainLimits.gymNameMax) ?? "",
                  address: GymCatalogRows.clip(address, to: DomainLimits.gymAddressMax),
                  latitude: GymCatalogRows.coordinate(latitude, within: 90),
                  longitude: GymCatalogRows.coordinate(longitude, within: 180), mapsPlaceId: mapsPlaceId)
    }
}

private struct ItemRow: Decodable {
    let id: UUID, kindId: String, brand: String?, model: String?, gymCount: Int, photoPath: String?
    let photoListingId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, brand, model, kindId = "kind_id", gymCount = "gym_count", photoPath = "photo_path",
             photoListingId = "photo_listing_id"
    }

    var item: RemoteItem {
        RemoteItem(id: id, kindId: kindId, brand: GymCatalogRows.clip(brand, to: DomainLimits.itemBrandMax),
                   model: GymCatalogRows.clip(model, to: DomainLimits.itemModelMax), gymCount: gymCount,
                   photoPath: GymCatalogRows.photoName(photoPath), photoListingId: photoListingId)
    }
}

/// A `public_gym_equipment` row, or one entry of a duplicates answer, which leaves out the gym, item, status and flags.
private struct ListingRow: Codable {
    let id: UUID, kindId: String, brand: String?, model: String?, photoPath: String?, loads: ListingLoads?
    let quantity: Int, confirmCount: Int
    let gymId: UUID?, itemId: UUID?, notes: String?, status: String?, isMine: Bool?, confirmedByMe: Bool?

    enum CodingKeys: String, CodingKey {
        case id, brand, model, loads, quantity, notes, status
        case kindId = "kind_id", photoPath = "photo_path", confirmCount = "confirm_count", gymId = "gym_id",
             itemId = "item_id", isMine = "is_mine", confirmedByMe = "confirmed_by_me"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kindId = try c.decode(String.self, forKey: .kindId)
        brand = try c.decodeIfPresent(String.self, forKey: .brand)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        photoPath = try c.decodeIfPresent(String.self, forKey: .photoPath)
        loads = try? c.decodeIfPresent(ListingLoads.self, forKey: .loads)
        quantity = try c.decode(Int.self, forKey: .quantity)
        confirmCount = try c.decode(Int.self, forKey: .confirmCount)
        gymId = try c.decodeIfPresent(UUID.self, forKey: .gymId)
        itemId = try c.decodeIfPresent(UUID.self, forKey: .itemId)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        isMine = try c.decodeIfPresent(Bool.self, forKey: .isMine)
        confirmedByMe = try c.decodeIfPresent(Bool.self, forKey: .confirmedByMe)
    }

    /// `share_listing` doesn't return the item id; a duplicate is only shown, never cached, so its own id stands in.
    func listing(gymId fallbackGym: UUID?) -> RemoteListing {
        RemoteListing(id: id, gymId: gymId ?? fallbackGym ?? id, itemId: itemId ?? id, kindId: kindId,
                      brand: GymCatalogRows.clip(brand, to: DomainLimits.itemBrandMax),
                      model: GymCatalogRows.clip(model, to: DomainLimits.itemModelMax),
                      photoPath: GymCatalogRows.photoName(photoPath), loads: loads.flatMap(GymCatalogRows.inLimits),
                      quantity: min(max(quantity, DomainLimits.listingQuantity.lowerBound),
                                    DomainLimits.listingQuantity.upperBound),
                      notes: GymCatalogRows.clip(notes, to: DomainLimits.listingNotesMax),
                      status: status ?? "active", confirmCount: max(confirmCount, 0), isMine: isMine ?? false,
                      confirmedByMe: confirmedByMe ?? false)
    }
}

private struct ModerationRow: Decodable {
    let targetType: GymTargetType, targetId: UUID, title: String, photoPath: String?, reportCount: Int
    let reasons: [String: Int], notes: [String]

    enum CodingKeys: String, CodingKey {
        case title, reasons, notes, targetType = "target_type", targetId = "target_id", photoPath = "photo_path",
             reportCount = "report_count"
    }

    var entry: ModerationEntry {
        let counted = reasons.map { ModerationEntry.ReasonCount(reason: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.reason) > ($1.count, $0.reason) }
        return ModerationEntry(targetType: targetType, targetId: targetId,
                               title: GymCatalogRows.clip(title, to: DomainLimits.gymNameMax) ?? "",
                               photoPath: GymCatalogRows.photoName(photoPath), reportCount: max(reportCount, 0),
                               reasons: counted,
                               notes: notes.compactMap { GymCatalogRows.clip($0, to: DomainLimits.reportNoteMax) })
    }
}

private struct ModerateAnswer: Decodable {
    let photoPath: String?

    enum CodingKeys: String, CodingKey { case photoPath = "photo_path" }
}

private struct ShareAnswer: Decodable {
    let status: String
    let listingId: UUID?
    let listings: [AnyJSONValue]

    enum CodingKeys: String, CodingKey { case status, listingId = "listing_id", listings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        listingId = try c.decodeIfPresent(UUID.self, forKey: .listingId)
        listings = try c.decodeIfPresent([AnyJSONValue].self, forKey: .listings) ?? []
    }
}

/// Any JSON value, kept as is so each listing in a duplicates answer is decoded on its own.
private enum AnyJSONValue: Codable {
    case null, bool(Bool), number(Double), string(String), array([AnyJSONValue]), object([String: AnyJSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([AnyJSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: AnyJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(v): try c.encode(v)
        case let .number(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        }
    }
}
