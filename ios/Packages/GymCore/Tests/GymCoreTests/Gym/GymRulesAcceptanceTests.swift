import Foundation
import Testing
@testable import GymCore

/// The spec's success criteria 1, 3 and 5 (docs/specs/2026-10-30-gym-equipment-design.md §1).
@Suite struct GymRulesAcceptanceTests {
    /// Every requirement group of the exercise is covered by a listing of the match, and every listing is at the gym.
    private func covers(_ match: InventoryMatch, _ exerciseId: String, _ inventory: GymInventory) -> Bool {
        guard let groups = GymFixtures.requirements.requirement(for: exerciseId) else { return false }
        let byId = Dictionary(uniqueKeysWithValues: inventory.listings.map { ($0.id, $0) })
        let used = match.listingIds.compactMap { byId[$0] }
        return used.count == match.listingIds.count
            && groups.allSatisfy { group in used.contains { group.contains($0.kindId) } }
    }

    @Test func criterion1NewGymWithFiveListingsBuildsAChestWorkoutFromThem() {
        let gym = GymInventory(gymName: "New gym", listings: [
            InventoryListing(id: GymFixtures.id(60), kindId: "dumbbells", loads: .fixed(kg: [10, 15, 20]), isOwn: true),
            InventoryListing(id: GymFixtures.id(61), kindId: "adjustable-bench", isOwn: true),
            InventoryListing(id: GymFixtures.id(62), kindId: "cable-station", loads: .stack(maxKg: 80, stepKg: 5), isOwn: true),
            InventoryListing(id: GymFixtures.id(63), kindId: "chest-press-machine", loads: .stack(maxKg: 100, stepKg: 5), isOwn: true),
            InventoryListing(id: GymFixtures.id(64), kindId: "pec-deck", loads: .stack(maxKg: 80, stepKg: 5), isOwn: true),
        ])
        let built = WorkoutBuilder(matcher: GymFixtures.matcher(gym), exercises: GymFixtures.exercises, history: [])
            .build(BuildRequest(muscles: [.chest], length: .medium, date: GymFixtures.date(day: 20_400)))
        #expect(built.items.count == 4)
        #expect(built.thin.isEmpty)
        for item in built.items {
            #expect(!item.isBodyweightFill)
            #expect(!item.match.listingIds.isEmpty)
            #expect(covers(item.match, item.exercise.exerciseId, gym), "\(item.exercise.exerciseId)")
        }
    }

    @Test func criterion3SameMusclesFourDaysInARowChangeAtLeastHalfEachTime() {
        let start = 20_400
        let results = (0..<4).reduce(into: (history: [Workout](), ids: [[String]]())) { state, offset in
            let built = WorkoutBuilder(matcher: GymFixtures.matcher(GymFixtures.iron), exercises: GymFixtures.exercises,
                                       history: state.history)
                .build(BuildRequest(muscles: [.chest], length: .short, date: GymFixtures.date(day: start + offset)))
            let ids = built.items.map(\.exercise.exerciseId)
            state.ids.append(ids)
            state.history.append(GymFixtures.workout(day: start + offset, ids))
        }.ids
        #expect(results.allSatisfy { $0.count == 3 })
        for (previous, next) in zip(results, results.dropFirst()) {
            let changed = Set(next).subtracting(previous).count
            #expect(changed * 2 >= next.count, "\(previous) → \(next)")
        }
    }

    @Test(arguments: 0..<40)
    func criterion5NeverInventsEquipment(seed: Int) {
        var random = SplitMix64(seed: UInt64(seed))
        let inventory = randomInventory(&random)
        let matcher = GymFixtures.matcher(inventory)
        let muscles = BuildMuscle.allCases.filter { _ in Bool.random(using: &random) }
        let length = BuildLength.allCases.randomElement(using: &random) ?? .short
        let built = WorkoutBuilder(matcher: matcher, exercises: GymFixtures.exercises, history: [])
            .build(BuildRequest(muscles: muscles, length: length, date: GymFixtures.date(day: 20_400 + seed)))
        for item in built.items {
            #expect(covers(item.match, item.exercise.exerciseId, inventory), "\(item.exercise.exerciseId)")
        }
        let machineUse = Dictionary(grouping: built.items.compactMap { item -> UUID? in
            guard let id = item.match.loadListingId, let listing = matcher.listing(id) else { return nil }
            return matcher.kind(listing.kindId)?.isMachine == true ? id : nil
        }, by: { $0 }).mapValues(\.count)
        #expect(machineUse.values.allSatisfy { $0 <= WorkoutBuilder.maxPerMachine })

        let routine = GymFixtures.exercises.enumerated().map { index, exercise in
            RoutineExercise(id: GymFixtures.id(500 + index), exerciseId: exercise.id, sets: 3, reps: 10)
        }
        for adapted in GymAdapter(matcher: matcher, exercises: GymFixtures.exercises).adapt(routine) {
            switch adapted {
            case let .kept(item, match): #expect(covers(match, item.exerciseId, inventory))
            case let .swapped(_, item, match, _): #expect(covers(match, item.exerciseId, inventory))
            case let .unavailable(item, _): #expect(matcher.availability(of: item.exerciseId) != .unmapped)
            case let .unmapped(item): #expect(matcher.availability(of: item.exerciseId) == .unmapped)
            }
        }
    }

    /// Each fixture kind is present with probability 1/2, as one or two listings with random confirmations.
    private func randomInventory(_ random: inout SplitMix64) -> GymInventory {
        var next = 1_000
        let listings = GymFixtures.kinds.flatMap { kind -> [InventoryListing] in
            guard Bool.random(using: &random) else { return [] }
            return (0..<Int.random(in: 1...2, using: &random)).map { _ in
                next += 1
                return InventoryListing(id: GymFixtures.id(next), kindId: kind.id,
                                        confirmCount: Int.random(in: 0...9, using: &random),
                                        isOwn: Bool.random(using: &random))
            }
        }
        return GymInventory(gymName: "Random", listings: listings)
    }
}

/// A small seeded generator, so the property test's inventories are the same on every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
