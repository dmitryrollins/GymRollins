/// The order Replace/Swap candidates are offered in: exercises with the same target, then with the same body part
/// (the current exercise excluded), each group by how often it was logged and then by name. `ExerciseRanking` applies
/// the owner's preferences on top. Shared by the Swap sheet (`ExerciseSuggestions.swap`) and `GymAdapter`.
public enum SwapOrdering {
    public static func candidates(for current: Exercise, in exercises: [Exercise],
                                  loggedCounts: [String: Int]) -> [Exercise] {
        func sorted(_ list: [Exercise]) -> [Exercise] {
            list.sorted { l, r in
                let lc = loggedCounts[l.id, default: 0], rc = loggedCounts[r.id, default: 0]
                return lc != rc ? lc > rc : l.name < r.name
            }
        }
        let sameTarget = exercises.filter { $0.id != current.id && $0.target == current.target }
        let sameBodyPart = exercises.filter {
            $0.id != current.id && $0.target != current.target && $0.bodyPart == current.bodyPart
        }
        return sorted(sameTarget) + sorted(sameBodyPart)
    }
}
