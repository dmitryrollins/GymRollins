import Foundation

/// What a finished workout shows about its gym's equipment (owner, 2026-11-18): the app never swaps for the gym, so
/// every exercise with a done set was done there, and its equipment is there. An exercise swapped out by hand isn't in
/// the workout, so nothing is learned from it.
public enum GymEquipmentLearning {
    /// Kind ids to add to the gym, in the order the workout first needs them. A requirement group the gym already
    /// covers, or one an earlier exercise added, adds nothing; a group of one kind adds that kind; a group of
    /// alternatives ("flat or adjustable bench") adds nothing, since the workout can't say which one was used.
    /// Bodyweight and unmapped exercises add nothing, and neither does a kind this app doesn't know.
    public static func kindsShown(by workout: Workout, requirements: ExerciseRequirements, knownKinds: Set<String>,
                                  listedKinds: Set<String>) -> [String] {
        var have = listedKinds
        var added: [String] = []
        for entry in workout.entries where entry.sets.contains(where: \.done) {
            for group in requirements.requirement(for: entry.exerciseId) ?? [] where have.isDisjoint(with: group) {
                guard group.count == 1, let kind = group.first, knownKinds.contains(kind) else { continue }
                have.insert(kind)
                added.append(kind)
            }
        }
        return added
    }
}
