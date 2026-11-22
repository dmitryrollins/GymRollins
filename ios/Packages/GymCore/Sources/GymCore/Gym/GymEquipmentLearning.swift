import Foundation

/// What a finished workout shows about its gym's equipment (owner, 2026-11-18): the app never swaps for the gym, so
/// every exercise with a done set was done there, and its equipment is there. An exercise swapped out by hand isn't in
/// the workout, so nothing is learned from it.
public enum GymEquipmentLearning {
    /// Kind ids to add to the gym, in the order the workout first needs them. A requirement group the gym already
    /// covers, or one an earlier exercise added, adds nothing; a group of one kind adds that kind; a group of
    /// alternatives ("flat or adjustable bench") adds its first kind this app knows (owner, 2026-11-22): the workout
    /// can't say which one was used, and the first is the one the exercise is named for.
    /// Bodyweight and unmapped exercises add nothing, and neither does a kind this app doesn't know.
    public static func kindsShown(by workout: Workout, requirements: ExerciseRequirements, knownKinds: Set<String>,
                                  listedKinds: Set<String>) -> [String] {
        var have = listedKinds
        var added: [String] = []
        for entry in workout.entries where entry.sets.contains(where: \.done) {
            for group in requirements.requirement(for: entry.exerciseId) ?? [] where have.isDisjoint(with: group) {
                guard let kind = group.first(where: knownKinds.contains) else { continue }
                have.insert(kind)
                added.append(kind)
            }
        }
        return added
    }

    /// The weights (kg) a workout shows for the gym's listings that hold a fixed set, by listing id: the done sets of
    /// each exercise go to the listing that decides its weight (`InventoryMatch.loadListingId`), so a bench never gets
    /// the weights of the dumbbells used on it. `matcher` reads the gym's listings after the kinds were added.
    public static func weightsShown(by workout: Workout, matcher: InventoryMatcher) -> [UUID: [Double]] {
        var seen: [UUID: [Double]] = [:]
        for entry in workout.entries {
            let kg = entry.sets.filter { $0.done && $0.weightKg > 0 }.map(\.weightKg)
            guard !kg.isEmpty, case let .available(match) = matcher.availability(of: entry.exerciseId),
                  let id = match.loadListingId, let listing = matcher.listing(id),
                  matcher.kind(listing.kindId)?.load == .fixedSet else { continue }
            seen[id, default: []] += kg
        }
        return seen.mapValues(LearnedWeights.distinct).filter { !$0.value.isEmpty }
    }
}
