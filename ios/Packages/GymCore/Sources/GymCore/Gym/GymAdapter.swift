import Foundation

/// One planned exercise after adapting today's routine to the current gym.
public enum AdaptedItem: Sendable, Hashable {
    /// Doable here, linked to the listings it uses.
    case kept(RoutineExercise, InventoryMatch)
    /// Not doable here; `replacement` (same item id) is the best available alternative. `missing` is the first
    /// requirement group of the planned exercise that the gym lacks.
    case swapped(planned: RoutineExercise, replacement: RoutineExercise, match: InventoryMatch, missing: [String])
    /// Not doable here and no similar exercise is.
    case unavailable(RoutineExercise, missing: [String])
    /// No requirements data: left as planned, unmarked.
    case unmapped(RoutineExercise)

    /// The exercise the session uses.
    public var item: RoutineExercise {
        switch self {
        case let .kept(item, _), let .unavailable(item, _), let .unmapped(item): item
        case let .swapped(_, replacement, _, _): replacement
        }
    }
}

/// Adapts a routine's exercises to the current gym for one session (spec §5). The routine itself is never edited:
/// the result only feeds today's list.
public struct GymAdapter: Sendable {
    private let matcher: InventoryMatcher
    private let exercises: [Exercise]
    private let byId: [String: Exercise]
    private let loggedCounts: [String: Int]
    private let preferences: [String: ExercisePreference]

    public init(matcher: InventoryMatcher, exercises: [Exercise], loggedCounts: [String: Int] = [:],
                preferences: [String: ExercisePreference] = [:]) {
        self.matcher = matcher
        self.exercises = exercises
        self.byId = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.loggedCounts = loggedCounts
        self.preferences = preferences
    }

    /// Adapts the items in order. A replacement is never an exercise already in the list or chosen for an earlier
    /// item.
    public func adapt(_ items: [RoutineExercise]) -> [AdaptedItem] {
        let start = (out: [AdaptedItem](), used: Set(items.map(\.exerciseId)))
        return items.reduce(into: start) { state, item in
            let adapted = adapt(item, excluding: state.used)
            state.used.insert(adapted.item.exerciseId)
            state.out.append(adapted)
        }.out
    }

    private func adapt(_ item: RoutineExercise, excluding used: Set<String>) -> AdaptedItem {
        switch matcher.availability(of: item.exerciseId) {
        case .unmapped: return .unmapped(item)
        case let .available(match): return .kept(item, match)
        case let .missing(kinds):
            guard let current = byId[item.exerciseId] else { return .unavailable(item, missing: kinds) }
            let ordered = ExerciseRanking.suggestions(
                SwapOrdering.candidates(for: current, in: exercises, loggedCounts: loggedCounts),
                preferences: preferences, id: \.id)
            for candidate in ordered where !used.contains(candidate.id) {
                if case let .available(match) = matcher.availability(of: candidate.id) {
                    return .swapped(planned: item, replacement: Self.replacement(for: item, with: candidate),
                                    match: match, missing: kinds)
                }
            }
            return .unavailable(item, missing: kinds)
        }
    }

    /// The planned item with another exercise: same id, sets, reps, rest-relevant targets and superset; no planned
    /// weight, so progression starts from the new exercise's own history. The increment follows the new equipment.
    /// Across modes the targets come from `RoutineExercise.defaults`.
    static func replacement(for item: RoutineExercise, with exercise: Exercise) -> RoutineExercise {
        let defaults = RoutineExercise.defaults(exerciseId: exercise.id, mode: exercise.mode,
                                                barbell: exercise.isBarbellLoaded)
        guard exercise.mode == item.mode else {
            return RoutineExercise(id: item.id, exerciseId: exercise.id, sets: defaults.sets, reps: defaults.reps,
                                   repsMin: defaults.repsMin, sec: defaults.sec, mode: defaults.mode,
                                   policy: defaults.policy, incKg: defaults.incKg, supersetGroup: item.supersetGroup)
        }
        return RoutineExercise(id: item.id, exerciseId: exercise.id, sets: item.sets, reps: item.reps,
                               repsMin: item.repsMin, sec: item.sec, mode: item.mode, policy: item.policy,
                               incKg: defaults.incKg, supersetGroup: item.supersetGroup)
    }
}
