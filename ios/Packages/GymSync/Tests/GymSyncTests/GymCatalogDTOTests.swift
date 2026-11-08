import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

struct GymCatalogDTOTests {
    private let listingId = "11111111-1111-1111-1111-111111111111"
    private let gymId = "22222222-2222-2222-2222-222222222222"
    private let itemId = "33333333-3333-3333-3333-333333333333"

    private func row(id: String? = nil, loads: String, extra: String = "") -> String {
        """
        {"id":"\(id ?? listingId)","gym_id":"\(gymId)","item_id":"\(itemId)","kind_id":"cable","brand":"Hammer",
         "model":null,"photo_path":null,"loads":\(loads),"quantity":2,"notes":"left corner","status":"active",
         "confirm_count":3,"created_at":"2026-10-30T10:00:00.123456+00:00","updated_at":"2026-10-30T10:00:00+00:00",
         "is_mine":false,"confirmed_by_me":true\(extra)}
        """
    }

    private func listings(_ json: String) -> [RemoteListing] { (try? GymCatalogRows.listings(from: Data(json.utf8)).rows) ?? [] }

    @Test func aListingRowDecodesWithEveryLoadShape() throws {
        let shapes: [(String, ListingLoads)] = [
            (#"{"type":"stack","maxKg":90,"stepKg":5}"#, .stack(maxKg: 90, stepKg: 5)),
            (#"{"type":"stack","maxKg":90}"#, .stack(maxKg: 90, stepKg: nil)),
            (#"{"type":"fixed","kg":[16,24]}"#, .fixed(kg: [16, 24])),
            (#"{"type":"plates"}"#, .plates),
            (#"{"type":"none"}"#, .none),
        ]
        for (json, expected) in shapes {
            let rows = listings("[\(row(loads: json))]")
            let listing = try #require(rows.first)
            #expect(listing.loads == expected)
            #expect(listing.id == UUID(uuidString: listingId))
            #expect(listing.gymId == UUID(uuidString: gymId))
            #expect(listing.itemId == UUID(uuidString: itemId))
            #expect(listing.kindId == "cable")
            #expect(listing.brand == "Hammer")
            #expect(listing.model == nil)
            #expect(listing.quantity == 2)
            #expect(listing.notes == "left corner")
            #expect(listing.confirmCount == 3)
            #expect(!listing.isMine)
            #expect(listing.confirmedByMe)
        }
    }

    @Test func anUnknownLoadsShapeComesBackWithNilLoads() throws {
        let rows = listings("[\(row(loads: #"{"type":"springs","n":3}"#))]")
        #expect(rows.count == 1)
        #expect(rows.first?.loads == nil)
        #expect(rows.first?.quantity == 2)
    }

    @Test func oneUnreadableRowDoesNotHideTheOthers() {
        let other = "44444444-4444-4444-4444-444444444444"
        let json = """
        [\(row(loads: #"{"type":"none"}"#)),
         {"id":"not-a-uuid","gym_id":"\(gymId)"},
         "garbage",
         \(row(id: other, loads: #"{"type":"plates"}"#))]
        """
        #expect(listings(json).map(\.id) == [UUID(uuidString: listingId)!, UUID(uuidString: other)!])
    }

    @Test func aBodyThatIsNotAnArrayThrows() {
        // A 200 with some other shape is a server this version can't read, not a gym with no equipment.
        let body = Data(#"{"message":"nope"}"#.utf8)
        #expect(throws: GymCatalogError.self) { try GymCatalogRows.listings(from: body) }
        #expect(throws: GymCatalogError.self) { try GymCatalogRows.gyms(from: body) }
        #expect(throws: GymCatalogError.self) { try GymCatalogRows.items(from: body) }
    }

    @Test func thePageSaysHowManyRowsItCouldNotRead() throws {
        let json = """
        [\(row(loads: #"{"type":"none"}"#)), {"id":"not-a-uuid"}, "garbage"]
        """
        let page = try GymCatalogRows.listings(from: Data(json.utf8))
        #expect(page.rows.count == 1)
        #expect(page.skipped == 2)
    }

    @Test func gymAndItemRowsDecodeOneAtATime() {
        let gyms = """
        [{"id":"\(gymId)","name":"Iron Works","address":"1 Main St","latitude":1.5,"longitude":-2.5,
          "maps_place_id":"p1","status":"active","is_mine":false},
         {"id":"bad"}]
        """
        let gym = try? GymCatalogRows.gyms(from: Data(gyms.utf8)).rows
        #expect(gym == [RemoteGym(id: UUID(uuidString: gymId)!, name: "Iron Works", address: "1 Main St",
                                  latitude: 1.5, longitude: -2.5, mapsPlaceId: "p1")])
        let items = """
        [{"id":"\(itemId)","kind_id":"cable","brand":null,"model":null,"photo_path":"\(goodName)",
          "photo_listing_id":"\(listingId)","gym_count":4},
         {"id":"\(itemId)"}]
        """
        #expect((try? GymCatalogRows.items(from: Data(items.utf8)).rows) == [
            RemoteItem(id: UUID(uuidString: itemId)!, kindId: "cable", brand: nil, model: nil, gymCount: 4,
                       photoPath: goodName, photoListingId: UUID(uuidString: listingId)),
        ])
    }

    // MARK: What the server sends is checked

    private let goodName = "3fa85f64-5717-4562-b3fc-2c963f66afa6.jpg"

    private func photoRow(_ path: String) -> String {
        row(loads: #"{"type":"none"}"#).replacingOccurrences(of: #""photo_path":null"#, with: #""photo_path":"\#(path)""#)
    }

    @Test func aPhotoPathThatIsNotAUuidJpgIsDropped() throws {
        for bad in ["../../x.jpg", "a/b.jpg", "\(goodName)/../y", "https://evil.test/a.jpg", "x.png"] {
            let listing = try #require(listings("[\(photoRow(bad))]").first)
            #expect(listing.photoPath == nil, "\(bad)")
            #expect(listing.quantity == 2, "the rest of the row is kept")
        }
        #expect(listings("[\(photoRow(goodName))]").first?.photoPath == goodName)
        let items = #"[{"id":"\#(itemId)","kind_id":"cable","brand":null,"model":null,"photo_path":"../z.jpg","gym_count":1}]"#
        #expect(try GymCatalogRows.items(from: Data(items.utf8)).rows.first?.photoPath == nil)
    }

    @Test func longTextIsClippedToTheLimits() throws {
        let long = String(repeating: "x", count: 500)
        let json = row(loads: #"{"type":"none"}"#)
            .replacingOccurrences(of: #""notes":"left corner""#, with: #""notes":"\#(long)""#)
            .replacingOccurrences(of: #""brand":"Hammer""#, with: #""brand":"\#(long)""#)
            .replacingOccurrences(of: #""model":null"#, with: #""model":"\#(long)""#)
        let listing = try #require(listings("[\(json)]").first)
        #expect(listing.notes?.count == DomainLimits.listingNotesMax)
        #expect(listing.brand?.count == DomainLimits.itemBrandMax)
        #expect(listing.model?.count == DomainLimits.itemModelMax)
        let gyms = #"[{"id":"\#(gymId)","name":"\#(long)","address":"\#(long)","latitude":999,"longitude":null,"maps_place_id":"p"}]"#
        let gym = try #require(try GymCatalogRows.gyms(from: Data(gyms.utf8)).rows.first)
        #expect(gym.name.count == DomainLimits.gymNameMax)
        #expect(gym.address?.count == DomainLimits.gymAddressMax)
        #expect(gym.latitude == nil, "a latitude off the globe is not used")
    }

    @Test func loadsOutsideTheLimitsMakeTheListingUnsupported() throws {
        for loads in [#"{"type":"stack","maxKg":5000}"#, #"{"type":"stack","maxKg":90,"stepKg":0}"#,
                      #"{"type":"fixed","kg":[]}"#, #"{"type":"fixed","kg":[900]}"#] {
            let listing = try #require(listings("[\(row(loads: loads))]").first)
            #expect(listing.loads == nil, "\(loads)")
        }
    }

    @Test func aNumberThatIsNotFiniteIsRefused() {
        // Such a number can't be parsed at all, so the page is unreadable and the cache is left alone.
        let body = Data("[\(row(loads: #"{"type":"stack","maxKg":1e999}"#))]".utf8)
        #expect(throws: GymCatalogError.self) { try GymCatalogRows.listings(from: body) }
    }

    @Test func aQuantityOutsideTheLimitsIsClamped() throws {
        let big = row(loads: #"{"type":"none"}"#).replacingOccurrences(of: #""quantity":2"#, with: #""quantity":900"#)
        #expect(listings("[\(big)]").first?.quantity == DomainLimits.listingQuantity.upperBound)
    }

    @Test func shareResultsDecode() throws {
        let created = try GymCatalogRows.shareResult(
            from: Data(#"{"status":"created","listing_id":"\#(listingId)"}"#.utf8), gymId: UUID(uuidString: gymId)!)
        #expect(created == .created(UUID(uuidString: listingId)!))

        let json = """
        {"status":"duplicates","listings":[{"id":"\(listingId)","kind_id":"cable","brand":"Hammer","model":null,
         "photo_path":"\(goodName)","loads":{"type":"stack","maxKg":80},"quantity":1,"confirm_count":2},
         {"id":"broken"}]}
        """
        let duplicates = try GymCatalogRows.shareResult(from: Data(json.utf8), gymId: UUID(uuidString: gymId)!)
        guard case let .duplicates(found) = duplicates else { Issue.record("expected duplicates"); return }
        #expect(found.count == 1)
        #expect(found[0].id == UUID(uuidString: listingId))
        #expect(found[0].gymId == UUID(uuidString: gymId))
        #expect(found[0].loads == .stack(maxKg: 80, stepKg: nil))
        #expect(found[0].confirmCount == 2)
        #expect(found[0].photoPath == goodName)
    }

    @Test func anUnknownShareStatusIsRejected() {
        #expect(throws: GymCatalogError.self) {
            try GymCatalogRows.shareResult(from: Data(#"{"status":"weird"}"#.utf8), gymId: UUID())
        }
    }
}
