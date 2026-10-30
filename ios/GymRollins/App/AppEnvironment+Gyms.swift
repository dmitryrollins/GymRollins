import Foundation
import GymCore
import GymData

/// The current gym and the rules that run on it (plan 19): matcher, adapter, loads and Build workout. Everything
/// reads the id from `defaults` (per device) and the gym's rows from `gyms`.
extension AppEnvironment {
    static let currentGymKey = "gymrollins.currentGymId"

    /// The gym the phone is at. Nil with none chosen, or when the stored id has no row (deleted, or the store was wiped).
    var currentGym: Gym? {
        _ = gymRevision // views that show the gym follow changes to it
        guard let id = storedGymId else { return nil }
        do { return try gyms.gym(id) }
        catch {
            Self.log.error("Read current gym failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private var storedGymId: UUID? { defaults.string(forKey: Self.currentGymKey).flatMap(UUID.init(uuidString:)) }

    func setCurrentGym(_ id: UUID?) {
        if let id { defaults.set(id.uuidString, forKey: Self.currentGymKey) }
        else { defaults.removeObject(forKey: Self.currentGymKey) }
        gymsChanged()
    }

    /// Deletes the gym, its listings and their photo files; if it was the current gym, none is current any more.
    func deleteGym(_ id: UUID) throws {
        let photos = try gyms.deleteGym(id)
        if storedGymId == id { defaults.removeObject(forKey: Self.currentGymKey) }
        removeGymPhotos(photos)
        gymsChanged()
    }

    /// Deletes photo files the repository handed back; one that can't be deleted is logged, not fatal.
    func removeGymPhotos(_ fileNames: [String]) {
        for name in fileNames {
            do { try gymPhotos.delete(name) }
            catch { Self.log.error("Delete gym photo failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// The rules' view of a gym (the current one by default); nil with no gym, or when the catalog didn't load.
    func gymMatcher(gymId: UUID? = nil) -> InventoryMatcher? {
        guard gymCatalog.isUsable, let id = gymId ?? currentGym?.id else { return nil }
        do {
            return InventoryMatcher(requirements: gymCatalog.requirements, kinds: gymCatalog.kinds,
                                    inventory: try gyms.inventory(gymId: id))
        } catch {
            Self.log.error("Read gym inventory failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func gymAdapter() -> GymAdapter? {
        guard let matcher = gymMatcher() else { return nil }
        return GymAdapter(matcher: matcher, exercises: library.exercises, loggedCounts: gymLoggedCounts(),
                          preferences: exercisePreferences)
    }

    /// How many of the 200 latest workouts include each exercise (Replace's "Logged N×", and the rules' tie-breaks).
    func gymLoggedCounts() -> [String: Int] {
        let recent: [Workout]
        do { recent = try workouts.recent(limit: 200) }
        catch {
            Self.log.error("Read logged counts failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
        return recent.reduce(into: [:]) { counts, workout in
            for entry in workout.entries { counts[entry.exerciseId, default: 0] += 1 }
        }
    }

    /// The loads of the listing that decides this exercise's weight at the current gym; nil with no gym or no such listing.
    func gymLoads(_ exerciseId: String) -> ListingLoads? { gymLoadsLookup()(exerciseId) }

    /// `gymLoads` for many exercises over one read of the gym.
    func gymLoadsLookup() -> (String) -> ListingLoads? {
        guard let matcher = gymMatcher() else { return { _ in nil } }
        return { matcher.loads(for: $0) }
    }

    /// What Today's rows need from the current gym, read once per reload.
    func todayGymContext() -> TodayGymContext? {
        guard let gym = currentGym, let matcher = gymMatcher(gymId: gym.id) else { return nil }
        let photos: [UUID: String]
        do {
            photos = try gyms.listings(gymId: gym.id).reduce(into: [:]) { result, listing in
                if let file = listing.photoFile { result[listing.id] = file }
            }
        } catch {
            Self.log.error("Read gym photos failed: \(error.localizedDescription, privacy: .public)")
            return TodayGymContext(matcher: matcher, photo: { _ in nil })
        }
        return TodayGymContext(matcher: matcher, photo: { photos[$0] })
    }

    /// Build workout at the current gym; nil with no gym. Chips with nothing doable here are thin or skipped in the
    /// result, as `WorkoutBuilder` decides.
    func buildWorkout(muscles: [BuildMuscle], length: BuildLength, avoid: [String]) -> BuiltWorkout? {
        guard let matcher = gymMatcher() else { return nil }
        let history: [Workout]
        do { history = try workouts.recent(limit: 60) }
        catch {
            Self.log.error("Read history for Build workout failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let builder = WorkoutBuilder(matcher: matcher, exercises: library.exercises, history: history,
                                     loggedCounts: gymLoggedCounts(), preferences: exercisePreferences)
        return builder.build(BuildRequest(muscles: muscles, length: length, date: now(), avoid: avoid))
    }
}

extension InventoryMatcher {
    /// The loads of the listing that decides this exercise's weight; nil when it has none here.
    func loads(for exerciseId: String) -> ListingLoads? {
        guard case let .available(match) = availability(of: exerciseId), let id = match.loadListingId else { return nil }
        return listing(id)?.loads
    }
}
