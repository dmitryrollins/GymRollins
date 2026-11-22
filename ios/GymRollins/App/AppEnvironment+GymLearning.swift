import Foundation
import GymCore
import GymData

/// What a finished workout added to its gym's equipment, for the summary: the kinds that are new, and for a fixed set
/// (dumbbells, kettlebells) the weights the listing now holds.
struct LearnedEquipment: Equatable {
    struct Kind: Equatable {
        let name: String
        let weightsKg: [Double]
    }

    let gymName: String
    let kinds: [Kind]

    var kindNames: [String] { kinds.map(\.name) }

    /// "Dumbbells (25 · 30 lb), Cable station": a fixed set names its weights in the user's unit.
    func label(unit: WeightUnit) -> String {
        kinds.map { kind in
            ListingLoadsText.text(.fixed(kg: kind.weightsKg), unit: unit).map { "\(kind.name) (\($0))" } ?? kind.name
        }.joined(separator: ", ")
    }
}

/// The gym's list fills in from training (owner, 2026-11-18): the app never swaps for the gym, so what a workout
/// there did is there.
extension AppEnvironment {
    /// Set once the catch-up over past workouts has run (`catchUpGymLearningOnce`).
    static let gymLearningCatchUpKey = "gymrollins.gymLearningCaughtUp"

    /// Adds what the finished workout shows its gym has (`GymEquipmentLearning`) as listings on this phone only: the
    /// generic item, no photo, and for dumbbells and kettlebells the weights used. Nil with no gym or no new kind. A
    /// listing that can't be added is logged and skipped; the workout is saved either way.
    @discardableResult
    func recordGymEquipment(from workout: Workout) -> LearnedEquipment? {
        let result = learnGymEquipment(from: workout)
        if result.changed { gymsChanged() }
        return result.learned
    }

    /// The same learning over every finished workout that has a gym, oldest first, once after the update (owner,
    /// 2026-11-22); run at launch. No card and no alert. A listing the owner deletes comes back only when a new workout
    /// uses it, as today, so it never runs again. Without a usable catalogue, or when the workouts can't be read, the
    /// marker stays unset and the next start tries again.
    func catchUpGymLearningOnce() {
        guard !defaults.bool(forKey: Self.gymLearningCatchUpKey), gymCatalog.isUsable else { return }
        let past: [Workout]
        do { past = try workouts.finished(endedSince: .distantPast) }
        catch {
            Self.log.error("Read workouts for gym learning failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // A gym is read once and read again only after a listing was added to it (weights don't change what is read).
        var reads: [UUID: GymRead] = [:]
        var changed = false
        for workout in past {
            guard let gymId = workout.gymId else { continue }
            let result = learnGymEquipment(from: workout, reading: reads[gymId])
            reads[gymId] = result.reads
            changed = changed || result.changed
        }
        defaults.set(true, forKey: Self.gymLearningCatchUpKey)
        if changed { gymsChanged() }
    }

    /// What learning reads about a gym: the gym, the kinds it lists and the rules' view of it.
    private struct GymRead {
        let gym: Gym
        let listed: Set<String>
        var matcher: InventoryMatcher?
    }

    private struct GymLearning {
        var learned: LearnedEquipment?
        var changed: Bool
        /// What was read, still true after the learning; nil when a listing was added or nothing could be read.
        var reads: GymRead?
        static let nothing = GymLearning(learned: nil, changed: false, reads: nil)
    }

    private func readGym(_ gymId: UUID) -> GymRead? {
        do {
            guard let gym = try gyms.gym(gymId) else { return nil }
            // Rows the rules skip (a newer app's kind, my own flagged listing) are still there: nothing is added twice.
            // One deleted or reported here comes back once a workout here uses it again: the workout shows it's there.
            let listed = Set(try gyms.listings(gymId: gymId, includingUnsupported: true).map(\.item.kindId))
            return GymRead(gym: gym, listed: listed, matcher: nil)
        } catch {
            Self.log.error("Read gym for learning failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// `known` is what an earlier workout of the same pass read about the gym (nil: read it now).
    private func learnGymEquipment(from workout: Workout, reading known: GymRead? = nil) -> GymLearning {
        guard let gymId = workout.gymId, gymCatalog.isUsable, var read = known ?? readGym(gymId) else { return .nothing }
        let kinds = GymEquipmentLearning.kindsShown(by: workout, requirements: gymCatalog.requirements,
                                                    knownKinds: Set(gymCatalog.kinds.map(\.id)), listedKinds: read.listed)
        var added: [String] = []
        for kind in kinds {
            do {
                try gyms.addListing(NewListing(gymId: gymId, kindId: kind))
                added.append(kind)
            } catch {
                Self.log.error("Add learned listing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        read.matcher = (added.isEmpty ? read.matcher : nil) ?? gymMatcher(gymId: gymId)
        let weightsChanged = read.matcher.map { learnWeights(from: workout, matcher: $0) } ?? false
        guard !added.isEmpty else { return GymLearning(learned: nil, changed: weightsChanged, reads: read) }
        return GymLearning(learned: learned(added, at: read.gym), changed: true, reads: nil)
    }

    /// Gives the gym's dumbbell and kettlebell listings the weights the workout used (`GymRepository.learnWeights`:
    /// a list the user made is left alone). True when a listing changed.
    private func learnWeights(from workout: Workout, matcher: InventoryMatcher) -> Bool {
        var changed = false
        for (listingId, kg) in GymEquipmentLearning.weightsShown(by: workout, matcher: matcher) {
            do { changed = try gyms.learnWeights(kg, forListing: listingId) || changed }
            catch { Self.log.error("Learn weights failed: \(error.localizedDescription, privacy: .public)") }
        }
        return changed
    }

    /// The summary's card: the new kinds by name, with the weights their listings now hold.
    private func learned(_ kindIds: [String], at gym: Gym) -> LearnedEquipment {
        let names = Dictionary(gymCatalog.kinds.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let listings: [GymListing]
        do { listings = try gyms.listings(gymId: gym.id) }
        catch {
            Self.log.error("Read learned listings failed: \(error.localizedDescription, privacy: .public)")
            listings = []
        }
        let kinds = kindIds.map { id in
            var weights: [Double] = []
            if case let .fixed(kg)? = listings.first(where: { $0.item.kindId == id })?.loads { weights = kg }
            return LearnedEquipment.Kind(name: names[id] ?? id, weightsKg: weights)
        }
        return LearnedEquipment(gymName: gym.name, kinds: kinds)
    }
}
