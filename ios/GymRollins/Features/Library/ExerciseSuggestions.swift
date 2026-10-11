import GymCore
import GymData

/// The exercise lists the app suggests, ordered by the owner's preferences (`ExerciseRanking`): `more` first, `less`
/// last, `never` hidden — unless the owner typed a search, which still finds every match (`never` ones last).
/// Preferences only order and filter suggestions; they never touch the plan or progression.
enum ExerciseSuggestions {
    /// Replace/Swap candidates: the same target, then the same body part (the current exercise excluded), each group
    /// by how often it was logged and then by name, then ranked by preference.
    static func swap(current: Exercise, library: ExerciseLibrary, loggedCounts: [String: Int],
                     preferences: [String: ExercisePreference], query: String) -> [Exercise] {
        func sorted(_ list: [Exercise]) -> [Exercise] {
            list.sorted { l, r in
                let lc = loggedCounts[l.id, default: 0], rc = loggedCounts[r.id, default: 0]
                return lc != rc ? lc > rc : l.name < r.name
            }
        }
        let sameTarget = library.exercises.filter { $0.id != current.id && $0.target == current.target }
        let sameBodyPart = library.exercises.filter {
            $0.id != current.id && $0.target != current.target && $0.bodyPart == current.bodyPart
        }
        let candidates = sorted(sameTarget) + sorted(sameBodyPart)
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else {
            return ExerciseRanking.suggestions(candidates, preferences: preferences, id: \.id)
        }
        let matches = candidates.filter { ex in words.allSatisfy { ex.name.lowercased().contains($0) } }
        return ExerciseRanking.searchResults(matches, preferences: preferences, id: \.id)
    }

    /// The exercise picker's rows. `hidesNever` is false where the owner must be able to pick anything (matching an
    /// imported exercise name): `never` exercises are then only moved to the end.
    static func picker(library: ExerciseLibrary, query: String, excluded: Set<String>,
                       preferences: [String: ExercisePreference], hidesNever: Bool) -> [Exercise] {
        let rows = library.search(query: query).filter { !excluded.contains($0.id) }
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        return hidesNever && !searching
            ? ExerciseRanking.suggestions(rows, preferences: preferences, id: \.id)
            : ExerciseRanking.searchResults(rows, preferences: preferences, id: \.id)
    }
}
