import Foundation

/// Picks the builder's exercises one slot at a time, keeping each exercise once and each machine listing to at most
/// `WorkoutBuilder.maxPerMachine` exercises.
struct SlotPicker {
    struct Pick: Sendable {
        let candidate: BuildCandidate
        let muscle: BuildMuscle
        let repeatOf: Date?
        let isFill: Bool
    }

    let matcher: InventoryMatcher
    let avoid: Set<String>
    private(set) var picked: [Pick] = []
    private var chosen: Set<String> = []
    private var machineUse: [UUID: Int] = [:]

    init(matcher: InventoryMatcher, avoid: Set<String>) {
        self.matcher = matcher
        self.avoid = avoid
    }

    /// Takes the best fresh equipment exercise for one slot: not done recently and not being rebuilt away from.
    mutating func pickFresh(from pool: BuildPool, muscle: BuildMuscle) -> Bool {
        let fresh = open(pool.equipment).first {
            pool.recent[$0.exercise.id] == nil && !avoid.contains($0.exercise.id)
        }
        guard let fresh else { return false }
        record(Pick(candidate: fresh, muscle: muscle, repeatOf: nil, isFill: false))
        return true
    }

    /// Takes the best candidate for a slot no fresh equipment exercise fit: a fresh no-equipment exercise, then a
    /// repeat (least recently done first), then what Rebuild is avoiding, because showing the same exercise again is
    /// the last resort. Only an exercise done recently is marked as a repeat.
    mutating func pickFallback(from pool: BuildPool, muscle: BuildMuscle) -> Bool {
        func lastDone(_ candidate: BuildCandidate) -> Date? { pool.recent[candidate.exercise.id] }
        func isAvoided(_ candidate: BuildCandidate) -> Bool { avoid.contains(candidate.exercise.id) }
        func leastRecentFirst(_ list: [BuildCandidate]) -> [BuildCandidate] {
            list.sorted { (lastDone($0) ?? .distantPast) < (lastDone($1) ?? .distantPast) }
        }
        let bodyweight = open(pool.bodyweight), all = open(pool.equipment) + bodyweight
        let tiers = [
            bodyweight.filter { lastDone($0) == nil && !isAvoided($0) },
            leastRecentFirst(all.filter { lastDone($0) != nil && !isAvoided($0) }),
            leastRecentFirst(all.filter(isAvoided)),
        ]
        guard let candidate = tiers.first(where: { !$0.isEmpty })?.first else { return false }
        record(Pick(candidate: candidate, muscle: muscle, repeatOf: lastDone(candidate),
                    isFill: matcher.needsNoEquipment(candidate.exercise.id)))
        return true
    }

    /// The pool without exercises already picked. A candidate on a machine at its cap moves to the gym's next best
    /// listing for it, and drops out when there is none.
    private func open(_ pool: [BuildCandidate]) -> [BuildCandidate] {
        let capped = Set(machineUse.filter { $0.value >= WorkoutBuilder.maxPerMachine }.keys)
        return pool.compactMap { candidate in
            guard !chosen.contains(candidate.exercise.id) else { return nil }
            guard let load = machineListing(candidate.match), capped.contains(load) else { return candidate }
            guard case let .available(match) = matcher.availability(of: candidate.exercise.id, excluding: capped) else {
                return nil
            }
            return BuildCandidate(exercise: candidate.exercise, match: match, compound: candidate.compound)
        }
    }

    private mutating func record(_ pick: Pick) {
        picked.append(pick)
        chosen.insert(pick.candidate.exercise.id)
        if let id = machineListing(pick.candidate.match) { machineUse[id, default: 0] += 1 }
    }

    /// The match's load listing when its kind is a machine.
    private func machineListing(_ match: InventoryMatch) -> UUID? {
        guard let id = match.loadListingId, let listing = matcher.listing(id),
              matcher.kind(listing.kindId)?.isMachine == true else { return nil }
        return id
    }
}
