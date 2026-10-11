import Foundation

/// How often the owner wants an exercise recommended (Fitbod's "Recommend more often / less often / Don't recommend
/// again"). It only orders and filters suggestions (Replace/Swap candidates, the exercise picker); it never changes
/// the plan or progression. Raw values are stored in `public.exercise_prefs.pref`.
public enum ExercisePreference: String, CaseIterable, Codable, Sendable {
    case more, normal, less, never

    /// Unknown or missing stored values read as `normal`.
    public init(storedValue: String?) {
        self = storedValue.flatMap(ExercisePreference.init(rawValue:)) ?? .normal
    }

    /// The menu's "Recommend more often" / "Recommend less often" toggles: turning the current choice off goes back
    /// to normal; turning the other one on replaces it (they are mutually exclusive, like `never`).
    public func toggled(_ choice: ExercisePreference) -> ExercisePreference {
        self == choice ? .normal : choice
    }

    /// Sort group: more (0) < normal (1) < less (2) < never (3).
    var rank: Int {
        switch self {
        case .more: 0
        case .normal: 1
        case .less: 2
        case .never: 3
        }
    }
}

/// Orders exercise suggestions by the owner's preferences. Stable: within one preference group the incoming order
/// (e.g. "most logged, then name") is kept.
public enum ExerciseRanking {
    /// Suggestions the app offers on its own: `more` first, `less` last, `never` removed.
    public static func suggestions<T>(_ items: [T], preferences: [String: ExercisePreference],
                                      id: (T) -> String) -> [T] {
        ranked(items, preferences: preferences, id: id).filter { preferences[id($0)] != .never }
    }

    /// Results of an explicit search: everything that matched, `never` ones last (the owner asked for them by name).
    public static func searchResults<T>(_ items: [T], preferences: [String: ExercisePreference],
                                        id: (T) -> String) -> [T] {
        ranked(items, preferences: preferences, id: id)
    }

    private static func ranked<T>(_ items: [T], preferences: [String: ExercisePreference],
                                  id: (T) -> String) -> [T] {
        guard !preferences.isEmpty else { return items }
        return items.enumerated()
            .sorted { a, b in
                let ra = (preferences[id(a.element)] ?? .normal).rank
                let rb = (preferences[id(b.element)] ?? .normal).rank
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }
}
