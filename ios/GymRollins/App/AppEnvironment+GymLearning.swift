import Foundation
import GymCore
import GymData

/// What a finished workout added to its gym's equipment, for the summary.
struct LearnedEquipment: Equatable {
    let gymName: String
    let kindNames: [String]
}

/// The gym's list fills in from training (owner, 2026-11-18): the app never swaps for the gym, so what a workout
/// there did is there.
extension AppEnvironment {
    /// Adds what the finished workout shows its gym has (`GymEquipmentLearning`) as listings on this phone only: the
    /// generic item, no photo, loads not known. Nil with no gym or nothing new. A listing that can't be added is logged
    /// and skipped; the workout is saved either way.
    @discardableResult
    func recordGymEquipment(from workout: Workout) -> LearnedEquipment? {
        guard let gymId = workout.gymId, gymCatalog.isUsable else { return nil }
        let gym: Gym
        let listed: Set<String>
        do {
            guard let found = try gyms.gym(gymId) else { return nil }
            gym = found
            // Rows the rules skip (a newer app's kind, my own flagged listing) are still there: nothing is added twice.
            // One deleted or reported here comes back once a workout here uses it again: the workout shows it's there.
            listed = Set(try gyms.listings(gymId: gymId, includingUnsupported: true).map(\.item.kindId))
        } catch {
            Self.log.error("Read gym for learning failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let kinds = GymEquipmentLearning.kindsShown(by: workout, requirements: gymCatalog.requirements,
                                                    knownKinds: Set(gymCatalog.kinds.map(\.id)), listedKinds: listed)
        var added: [String] = []
        for kind in kinds {
            do {
                try gyms.addListing(NewListing(gymId: gymId, kindId: kind))
                added.append(kind)
            } catch {
                Self.log.error("Add learned listing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !added.isEmpty else { return nil }
        gymsChanged()
        let names = Dictionary(gymCatalog.kinds.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return LearnedEquipment(gymName: gym.name, kindNames: added.map { names[$0] ?? $0 })
    }
}
