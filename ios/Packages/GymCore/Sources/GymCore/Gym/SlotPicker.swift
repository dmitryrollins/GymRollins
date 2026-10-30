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

    /// Takes the best open candidate for one slot: a fresh one (not recent, not avoided) first, then an avoided one,
    /// then a recent one, least recently done first, which is marked as a repeat. Returns false when none is open.
    mutating func pick(from pool: [BuildCandidate], recent: [String: Date], muscle: BuildMuscle, fill: Bool) -> Bool {
        let open = pool.filter { !chosen.contains($0.exercise.id) && fitsMachineCap($0.match) }
        let notRecent = open.filter { recent[$0.exercise.id] == nil }
        let fresh = notRecent.first { !avoid.contains($0.exercise.id) } ?? notRecent.first
        let repeated = open.filter { recent[$0.exercise.id] != nil }
            .min { recent[$0.exercise.id] ?? .distantFuture < recent[$1.exercise.id] ?? .distantFuture }
        guard let candidate = fresh ?? repeated else { return false }
        let repeatOf = fresh == nil ? recent[candidate.exercise.id] : nil
        record(Pick(candidate: candidate, muscle: muscle, repeatOf: repeatOf, isFill: fill))
        return true
    }

    private mutating func record(_ pick: Pick) {
        picked.append(pick)
        chosen.insert(pick.candidate.exercise.id)
        if let id = machineListing(pick.candidate.match) { machineUse[id, default: 0] += 1 }
    }

    private func fitsMachineCap(_ match: InventoryMatch) -> Bool {
        guard let id = machineListing(match) else { return true }
        return machineUse[id, default: 0] < WorkoutBuilder.maxPerMachine
    }

    /// The match's load listing when its kind is a machine.
    private func machineListing(_ match: InventoryMatch) -> UUID? {
        guard let id = match.loadListingId, let listing = matcher.listing(id),
              matcher.kind(listing.kindId)?.isMachine == true else { return nil }
        return id
    }
}
