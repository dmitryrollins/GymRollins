import Foundation
import GymCore
import GymData
import Supabase
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
        [{"id":"\(itemId)","kind_id":"cable","brand":null,"model":null,"photo_path":"a.jpg",
          "photo_listing_id":"\(listingId)","gym_count":4},
         {"id":"\(itemId)"}]
        """
        #expect((try? GymCatalogRows.items(from: Data(items.utf8)).rows) == [
            RemoteItem(id: UUID(uuidString: itemId)!, kindId: "cable", brand: nil, model: nil, gymCount: 4,
                       photoPath: "a.jpg", photoListingId: UUID(uuidString: listingId)),
        ])
    }

    @Test func theListingReadStopsAtItsCapAndSaysSo() async throws {
        let two = "[\(row(loads: #"{"type":"none"}"#)), \(row(loads: #"{"type":"none"}"#))]"
        var starts: [Int] = []
        let capped = try await SupabaseGymCatalogTransport.readListings(pageSize: 2, maxPages: 2) { start in
            starts.append(start)
            return Data(two.utf8)
        }
        #expect(starts == [0, 2])
        #expect(capped.capped)
        #expect(!capped.isComplete)

        let short = try await SupabaseGymCatalogTransport.readListings(pageSize: 3, maxPages: 2) { _ in Data(two.utf8) }
        #expect(!short.capped)
        #expect(short.isComplete)
    }

    @Test func shareResultsDecode() throws {
        let created = try GymCatalogRows.shareResult(
            from: Data(#"{"status":"created","listing_id":"\#(listingId)"}"#.utf8), gymId: UUID(uuidString: gymId)!)
        #expect(created == .created(UUID(uuidString: listingId)!))

        let json = """
        {"status":"duplicates","listings":[{"id":"\(listingId)","kind_id":"cable","brand":"Hammer","model":null,
         "photo_path":"p.jpg","loads":{"type":"stack","maxKg":80},"quantity":1,"confirm_count":2},
         {"id":"broken"}]}
        """
        let duplicates = try GymCatalogRows.shareResult(from: Data(json.utf8), gymId: UUID(uuidString: gymId)!)
        guard case let .duplicates(found) = duplicates else { Issue.record("expected duplicates"); return }
        #expect(found.count == 1)
        #expect(found[0].id == UUID(uuidString: listingId))
        #expect(found[0].gymId == UUID(uuidString: gymId))
        #expect(found[0].loads == .stack(maxKg: 80, stepKg: nil))
        #expect(found[0].confirmCount == 2)
        #expect(found[0].photoPath == "p.jpg")
    }

    @Test func anUnknownShareStatusIsRejected() {
        #expect(throws: GymCatalogError.self) {
            try GymCatalogRows.shareResult(from: Data(#"{"status":"weird"}"#.utf8), gymId: UUID())
        }
    }

    // MARK: Errors

    private func postgrest(_ message: String, code: String?) -> PostgrestError {
        PostgrestError(detail: nil, hint: nil, code: code, message: message)
    }

    @Test func serverMessagesMapOntoTheOutboxCases() {
        #expect(GymCatalogErrors.map(postgrest("daily_limit", code: "P0001")) == .dailyLimit)
        #expect(GymCatalogErrors.map(postgrest("gym_not_shareable", code: "P0001")) == .gymNotShareable)
        #expect(GymCatalogErrors.map(postgrest("photo_missing", code: "P0001")) == .photoMissing)
        #expect(GymCatalogErrors.map(postgrest("not allowed", code: "42501")) == .signedOut)
        #expect(GymCatalogErrors.map(postgrest("JWT expired", code: "PGRST301")) == .signedOut)
        #expect(GymCatalogErrors.map(postgrest("photo_in_use", code: "P0001")) == .rejected("photo_in_use"))
        #expect(GymCatalogErrors.map(postgrest("invalid loads", code: "22023")) == .rejected("invalid loads"))
    }

    @Test func networkAndAuthFailuresMap() {
        #expect(GymCatalogErrors.map(URLError(.notConnectedToInternet)) == .offline)
        #expect(GymCatalogErrors.map(URLError(.timedOut)) == .offline)
        #expect(GymCatalogErrors.map(AuthError.sessionMissing) == .signedOut)
    }

    @Test func storageAnswersAreToldApart() {
        let duplicate = StorageError(statusCode: "409", message: "The resource already exists", error: "Duplicate")
        #expect(GymCatalogErrors.isDuplicateUpload(duplicate))
        let refused = StorageError(statusCode: "403", message: "new row violates row-level security policy",
                                   error: "Unauthorized")
        #expect(!GymCatalogErrors.isDuplicateUpload(refused))
        #expect(GymCatalogErrors.map(refused) == .rejected("new row violates row-level security policy"))
        #expect(GymCatalogErrors.map(StorageError(statusCode: "401", message: "bad jwt", error: "Unauthorized"))
                == .signedOut)
    }
}
