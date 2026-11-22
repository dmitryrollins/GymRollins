import Foundation

/// Which Apple Maps places count as gyms. Maps tags most gyms as fitness centers, but some have no category at all
/// (often a gym inside a bigger sports complex), so the fitness-center filter alone hides them. An untagged place
/// counts in a search when its name matches what was searched for (`nameMatches`), and nearby when its name has a
/// gym word.
enum GymPlaceMatching {
    /// Words in an untagged place's name that make it a gym when the phone is close to it.
    static let gymWords = [
        "gym", "fitness", "crossfit", "yoga", "pilates", "barre", "boxing", "climbing", "bouldering", "athletic",
        "health club", "sports club", "martial arts", "jiu-jitsu", "karate", "muay thai", "powerlifting",
        "weightlifting",
    ]

    /// Searched words that say "a gym" without naming one: "Harbor Yards gym" means the gym called Harbor Yards
    /// Fitness.
    static let genericWords: Set<String> = ["gym", "gyms", "fitness", "club", "health", "studio", "center", "centre"]

    /// Places whose name matches the search come first: fitness centers, then the rest of Maps, or, with the
    /// phone's location, nearest first (a chain's club nearby before its flagship across town). The other fitness
    /// centers Maps found for the text follow. Each place is listed once.
    static func searchResults(query: String, fitnessCenters: [GymPlace], others: [GymPlace],
                              near: GymCoordinate? = nil) -> [GymPlace] {
        let named = unique((fitnessCenters + others).filter { nameMatches(query: query, $0.name) })
        return unique(nearestFirst(named, to: near) + fitnessCenters)
    }

    /// The name has every word searched for, or, when the search has generic words ("gym"), every other word and a
    /// gym word: "Harbor Yards gym" finds "Harbor Yards Fitness", not the "Harbor Yards" complex or its cafe.
    static func nameMatches(query: String, _ name: String) -> Bool {
        if nameHasEveryWord(of: query, name) { return true }
        let words = words(of: query)
        let specific = words.filter { !genericWords.contains($0.lowercased()) }
        guard !specific.isEmpty, specific.count < words.count, looksLikeGym(name) else { return false }
        let name = withoutApostrophes(name)
        return specific.allSatisfy { name.localizedStandardContains($0) }
    }

    /// Every fitness center nearby, then untagged places whose name says gym. Each place is listed once.
    static func nearbyResults(fitnessCenters: [GymPlace], others: [GymPlace]) -> [GymPlace] {
        unique(fitnessCenters + others.filter { looksLikeGym($0.name) })
    }

    /// Every word of `query` is in `name`, ignoring case, accents and apostrophes ("golds" finds "Gold's Gym").
    static func nameHasEveryWord(of query: String, _ name: String) -> Bool {
        let words = words(of: query)
        let name = withoutApostrophes(name)
        return !words.isEmpty && words.allSatisfy { name.localizedStandardContains($0) }
    }

    static func looksLikeGym(_ name: String) -> Bool {
        gymWords.contains { name.localizedStandardContains($0) }
    }

    private static func words(of query: String) -> [String] {
        withoutApostrophes(query).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func withoutApostrophes(_ text: String) -> String {
        text.replacing(/['’]/, with: "")
    }

    /// Closest to `near` first, equal distances keeping their order; Maps' order without a location.
    private static func nearestFirst(_ places: [GymPlace], to near: GymCoordinate?) -> [GymPlace] {
        guard let near else { return places }
        return places.enumerated()
            .map { (offset: $0.offset, place: $0.element, meters: near.distance(to: $0.element.coordinate)) }
            .sorted { $0.meters != $1.meters ? $0.meters < $1.meters : $0.offset < $1.offset }
            .map(\.place)
    }

    private static func unique(_ places: [GymPlace]) -> [GymPlace] {
        var seen = Set<String>()
        return places.filter { seen.insert($0.placeId).inserted }
    }
}
