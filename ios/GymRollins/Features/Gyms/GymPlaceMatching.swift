import Foundation

/// Which Apple Maps places count as gyms. Maps tags most gyms as fitness centers, but some have no category at all
/// (often a gym inside a bigger sports complex), so the fitness-center filter alone hides them. An untagged place
/// counts in a search when its name has every word searched for, and nearby when its name has a gym word.
enum GymPlaceMatching {
    /// Words in an untagged place's name that make it a gym when the phone is close to it.
    static let gymWords = [
        "gym", "fitness", "crossfit", "yoga", "pilates", "barre", "boxing", "climbing", "bouldering", "athletic",
        "health club", "sports club", "martial arts", "jiu-jitsu", "karate", "muay thai", "powerlifting",
        "weightlifting",
    ]

    /// Places whose name has every word searched for come first: fitness centers, then the rest of Maps. The other
    /// fitness centers Maps found for the text follow. Each place is listed once.
    static func searchResults(query: String, fitnessCenters: [GymPlace], others: [GymPlace]) -> [GymPlace] {
        let named = (fitnessCenters + others).filter { nameHasEveryWord(of: query, $0.name) }
        return unique(named + fitnessCenters)
    }

    /// Every fitness center nearby, then untagged places whose name says gym. Each place is listed once.
    static func nearbyResults(fitnessCenters: [GymPlace], others: [GymPlace]) -> [GymPlace] {
        unique(fitnessCenters + others.filter { looksLikeGym($0.name) })
    }

    /// Every word of `query` is in `name`, ignoring case, accents and apostrophes ("golds" finds "Gold's Gym").
    static func nameHasEveryWord(of query: String, _ name: String) -> Bool {
        let words = withoutApostrophes(query).split { !$0.isLetter && !$0.isNumber }
        let name = withoutApostrophes(name)
        return !words.isEmpty && words.allSatisfy { name.localizedStandardContains($0) }
    }

    static func looksLikeGym(_ name: String) -> Bool {
        gymWords.contains { name.localizedStandardContains($0) }
    }

    private static func withoutApostrophes(_ text: String) -> String {
        text.replacing(/['’]/, with: "")
    }

    private static func unique(_ places: [GymPlace]) -> [GymPlace] {
        var seen = Set<String>()
        return places.filter { seen.insert($0.placeId).inserted }
    }
}
