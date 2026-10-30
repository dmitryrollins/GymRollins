import Foundation

/// An exercise the builder may use for a chip at this gym.
struct BuildCandidate: Sendable {
    let exercise: Exercise
    let match: InventoryMatch
    /// Trains two or more muscle groups (`MuscleTaxonomy.contributions`).
    let compound: Bool
}

/// A chip's candidates, ranked best first, plus the exercises recently done for it.
struct BuildPool: Sendable {
    let equipment: [BuildCandidate]
    let bodyweight: [BuildCandidate]
    /// Exercise id → the latest day it was done, from the last `recentWorkoutsPerMuscle` workouts for the chip.
    let recent: [String: Date]
}

extension WorkoutBuilder {
    /// Rep exercises whose primary muscle is in the chip, available at the gym and not marked `never`, ranked:
    /// `more` first and `less` last, then the listing with more confirmations (own listings count as one), then
    /// the more-logged exercise, then a tie-break seeded by the day.
    func pool(for muscle: BuildMuscle, day: Int) -> BuildPool {
        let ranked = exercises.compactMap { candidate($0, for: muscle) }.sorted { ranksBefore($0, $1, day: day) }
        return BuildPool(equipment: ranked.filter { !matcher.needsNoEquipment($0.exercise.id) },
                         bodyweight: ranked.filter { matcher.needsNoEquipment($0.exercise.id) },
                         recent: recent(for: muscle))
    }

    private func candidate(_ exercise: Exercise, for muscle: BuildMuscle) -> BuildCandidate? {
        guard exercise.mode == .reps, preferences[exercise.id] != .never else { return nil }
        let contributions = MuscleTaxonomy.contributions(for: exercise)
        guard contributions.contains(where: { $0.isPrimary && muscle.groups.contains($0.group) }),
              case let .available(match) = matcher.availability(of: exercise.id) else { return nil }
        return BuildCandidate(exercise: exercise, match: match, compound: contributions.count >= 2)
    }

    private func ranksBefore(_ a: BuildCandidate, _ b: BuildCandidate, day: Int) -> Bool {
        let pa = (preferences[a.exercise.id] ?? .normal).rank, pb = (preferences[b.exercise.id] ?? .normal).rank
        if pa != pb { return pa < pb }
        let sa = score(a.match), sb = score(b.match)
        if sa != sb { return sa > sb }
        let la = loggedCounts[a.exercise.id, default: 0], lb = loggedCounts[b.exercise.id, default: 0]
        if la != lb { return la > lb }
        return StableHash.fnv1a("\(day)|\(a.exercise.id)") < StableHash.fnv1a("\(day)|\(b.exercise.id)")
    }

    private func score(_ match: InventoryMatch) -> Int {
        (match.loadListingId ?? match.listingIds.first).flatMap { matcher.listing($0)?.score } ?? 0
    }

    /// The exercises of the latest `recentWorkoutsPerMuscle` workouts that trained the chip (any entry whose primary
    /// muscle is in it), each with the latest day it was done.
    private func recent(for muscle: BuildMuscle) -> [String: Date] {
        let trained = history.filter { workout in
            workout.entries.contains { entry in byId[entry.exerciseId].map { trains($0, muscle) } ?? false }
        }
        return trained.prefix(Self.recentWorkoutsPerMuscle).reduce(into: [:]) { dates, workout in
            for entry in workout.entries where dates[entry.exerciseId] == nil {
                dates[entry.exerciseId] = workout.startedAt
            }
        }
    }

    private func trains(_ exercise: Exercise, _ muscle: BuildMuscle) -> Bool {
        MuscleTaxonomy.contributions(for: exercise).contains { $0.isPrimary && muscle.groups.contains($0.group) }
    }
}
