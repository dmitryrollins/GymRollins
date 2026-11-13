import Testing
@testable import GymRollins

/// Some gyms have no category on Apple Maps (often a gym inside a bigger sports complex), so the fitness-center
/// filter alone hides them. Untagged places count when their name has every word searched for, or, nearby, a gym word.
@Suite struct GymPlaceMatchingTests {
    private func place(_ id: String, _ name: String) -> GymPlace {
        GymPlace(placeId: id, name: name, address: nil, coordinate: GymCoordinate(latitude: 1, longitude: 2))
    }

    private var ironWorks: GymPlace { place("iron", "Iron Works Gym") }
    private var harborFitness: GymPlace { place("harbor", "Harbor Yards Fitness") }
    private var harborCafe: GymPlace { place("cafe", "Harbor Yards Cafe") }

    @Test func untaggedPlaceNamedAsSearchedComesFirst() {
        let found = GymPlaceMatching.searchResults(query: "Harbor Yards Fitness",
                                                   fitnessCenters: [ironWorks], others: [harborCafe, harborFitness])
        #expect(found == [harborFitness, ironWorks])
    }

    @Test func fitnessCenterNamedAsSearchedBeatsUntaggedOne() {
        let tagged = place("tagged", "Harbor Yards Fitness Annex")
        let found = GymPlaceMatching.searchResults(query: "harbor yards fitness",
                                                   fitnessCenters: [ironWorks, tagged], others: [harborFitness])
        #expect(found == [tagged, harborFitness, ironWorks])
    }

    @Test func untaggedPlacesWithoutEveryWordAreLeftOut() {
        let found = GymPlaceMatching.searchResults(query: "harbor fitness", fitnessCenters: [], others: [harborCafe])
        #expect(found.isEmpty)
    }

    @Test func aPlaceInBothListsIsListedOnce() {
        let found = GymPlaceMatching.searchResults(query: "iron works",
                                                   fitnessCenters: [ironWorks], others: [ironWorks, harborFitness])
        #expect(found == [ironWorks])
    }

    @Test func wordsMatchPartlyAndIgnoreCaseAccentsAndApostrophes() {
        #expect(GymPlaceMatching.nameHasEveryWord(of: "harb YÁRDS", "Harbor Yards Fitness"))
        #expect(GymPlaceMatching.nameHasEveryWord(of: "golds gym", "Gold's Gym"))
        #expect(GymPlaceMatching.nameHasEveryWord(of: "gold’s", "Golds Gym"))
        #expect(!GymPlaceMatching.nameHasEveryWord(of: "harbor pool", "Harbor Yards Fitness"))
        #expect(!GymPlaceMatching.nameHasEveryWord(of: "  ", "Harbor Yards Fitness"))
    }

    @Test func blankSearchKeepsOnlyFitnessCenters() {
        let found = GymPlaceMatching.searchResults(query: " ", fitnessCenters: [ironWorks], others: [harborFitness])
        #expect(found == [ironWorks])
    }

    @Test func nearbyKeepsFitnessCentersAndUntaggedPlacesNamedLikeGyms() {
        let deli = place("deli", "Corner Deli")
        let yoga = place("yoga", "Sunrise YOGA Loft")
        let found = GymPlaceMatching.nearbyResults(fitnessCenters: [ironWorks],
                                                   others: [deli, harborFitness, ironWorks, yoga, harborCafe])
        #expect(found == [ironWorks, harborFitness, yoga])
    }

    @Test(arguments: ["Gymnasium on 5th", "Bay CrossFit", "Pilates Studio", "Rock Climbing Hall", "Northside Athletic Club",
                      "Downtown Boxing", "Barre & Co", "Westside Health Club"])
    func gymWordsMakeAnUntaggedPlaceAGym(_ name: String) {
        #expect(GymPlaceMatching.looksLikeGym(name))
    }

    @Test(arguments: ["Corner Deli", "Harbor Yards Cafe", "Pier 12 Parking", "City Library"])
    func otherPlacesAreNotGyms(_ name: String) {
        #expect(!GymPlaceMatching.looksLikeGym(name))
    }
}
