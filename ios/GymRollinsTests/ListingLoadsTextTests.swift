import GymCore
import Testing
@testable import GymRollins

@Suite struct ListingLoadsTextTests {
    @Test func stackShowsItsTop() {
        #expect(ListingLoadsText.text(.stack(maxKg: 113.4, stepKg: nil), unit: .lb) == "to 250 lb")
        #expect(ListingLoadsText.text(.stack(maxKg: 113.4, stepKg: 5), unit: .kg) == "to 113 kg")
    }

    @Test func fixedSetListsEveryWeight() {
        #expect(ListingLoadsText.text(.fixed(kg: [20, 24]), unit: .lb) == "44 \u{00B7} 53 lb")
        #expect(ListingLoadsText.text(.fixed(kg: [24, 20]), unit: .kg) == "20 \u{00B7} 24 kg")
        #expect(ListingLoadsText.text(.fixed(kg: [2.5, 5]), unit: .kg) == "2.5 \u{00B7} 5 kg")
        #expect(ListingLoadsText.text(.fixed(kg: []), unit: .kg) == nil)
    }

    @Test func platesAndNoneAreShortOrEmpty() {
        #expect(ListingLoadsText.text(.plates, unit: .lb) == "plate-loaded")
        #expect(ListingLoadsText.text(.none, unit: .lb) == nil)
    }
}
