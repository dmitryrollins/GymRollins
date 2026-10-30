import Foundation
import Testing
@testable import GymCore

@Suite struct GymInventoryTests {
    @Test(arguments: [
        (#"{"type":"stack","maxKg":113.4,"stepKg":4.5}"#, ListingLoads.stack(maxKg: 113.4, stepKg: 4.5)),
        (#"{"type":"stack","maxKg":90}"#, ListingLoads.stack(maxKg: 90, stepKg: nil)),
        (#"{"type":"fixed","kg":[20,24]}"#, ListingLoads.fixed(kg: [20, 24])),
        (#"{"type":"plates"}"#, ListingLoads.plates),
        (#"{"type":"none"}"#, ListingLoads.none),
    ])
    func loadsDecodeAndRoundTrip(json: String, expected: ListingLoads) throws {
        let decoded = try JSONDecoder().decode(ListingLoads.self, from: Data(json.utf8))
        #expect(decoded == expected)
        let again = try JSONDecoder().decode(ListingLoads.self, from: JSONEncoder().encode(decoded))
        #expect(again == expected)
    }

    @Test func unknownLoadsTypeThrows() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ListingLoads.self, from: Data(#"{"type":"magic"}"#.utf8))
        }
    }

    @Test func ownListingsScoreOneMoreConfirmation() {
        #expect(InventoryListing(id: UUID(), kindId: "x", confirmCount: 3, isOwn: true).score == 4)
        #expect(InventoryListing(id: UUID(), kindId: "x", confirmCount: 3).score == 3)
    }
}
