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

    @Test func aMissingStepIsLeftOutOfTheStoredShape() throws {
        let encoded = try JSONEncoder().encode(ListingLoads.stack(maxKg: 90, stepKg: nil))
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains(#""type":"stack""#))
        #expect(json.contains(#""maxKg":90"#))
        #expect(!json.contains("stepKg"))
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

    /// Weights a workout showed are only "seen so far": the rules see no loads for them, so a suggestion isn't snapped
    /// to them or capped at the heaviest.
    @Test func loadsFromWorkoutsAreNotUsedToFitSuggestions() {
        let learned = InventoryListing(id: UUID(), kindId: "dumbbells", loads: .fixed(kg: [10, 12]), isOwn: true,
                                       loadsFromWorkouts: true)
        let chosen = InventoryListing(id: UUID(), kindId: "dumbbells", loads: .fixed(kg: [10, 12]), isOwn: true)
        #expect(learned.loadsFromWorkouts)
        #expect(learned.loads == .none)
        #expect(AvailableLoads.fit(weightKg: 20, reps: 8, to: learned.loads).weightKg == 20)
        #expect(chosen.loads == .fixed(kg: [10, 12]))
        #expect(AvailableLoads.fit(weightKg: 20, reps: 8, to: chosen.loads).atHeaviest)
    }

    @Test func hasNoWeightsOnlyForAnEmptyFixedSetOrNone() {
        #expect(ListingLoads.none.hasNoWeights)
        #expect(ListingLoads.fixed(kg: []).hasNoWeights)
        #expect(!ListingLoads.fixed(kg: [10]).hasNoWeights)
        #expect(!ListingLoads.plates.hasNoWeights)
        #expect(!ListingLoads.stack(maxKg: 90, stepKg: nil).hasNoWeights)
    }
}
