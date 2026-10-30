import Foundation
import GymCore
import GymData

/// The current gym and the rules that run on it (plan 19): matcher, adapter, loads and Build workout. Everything
/// reads the id from `defaults` (per device) and the gym's rows from `gyms`.
extension AppEnvironment {
    static let currentGymKey = "gymrollins.currentGymId"
    static let gymLocationCheckedKey = "gymrollins.gymLocationCheckedAt"

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

    /// Deletes the listing and its photo files together.
    func removeListing(_ id: UUID) throws {
        let photo = try gyms.removeListing(id)
        removeGymPhotos(photo.map { [$0] } ?? [])
        gymsChanged()
    }

    /// Saves the cleaned photo and attaches it to the listing, deleting the one it replaces. If the listing can't take
    /// it, the file just written goes again, so nothing is left behind.
    func attachPhoto(_ photo: ProcessedGymPhoto, to listingId: UUID) throws {
        let file = try gymPhotos.save(photo)
        do {
            let previous = try gyms.setPhoto(listingId, file: file)
            removeGymPhotos(previous.map { [$0] } ?? [])
        } catch {
            removeGymPhotos([file])
            throw error
        }
        gymsChanged()
    }

    /// The equipment screen's coverage numbers for a gym. The rules run a full candidate pass per chip, so this is
    /// done off the main actor; empty when there's no usable catalog.
    func gymCoverage(gymId: UUID) async -> [GymEquipmentModel.Coverage] {
        guard let matcher = gymMatcher(gymId: gymId) else { return [] }
        let exercises = library.exercises, date = now()
        return await Task.detached(priority: .userInitiated) {
            GymEquipmentModel.coverage(matcher: matcher, exercises: exercises, asOf: date)
        }.value
    }

    /// Picks a gym from Maps: stored as a local gym (once), then made current.
    @discardableResult
    func chooseMapsGym(_ place: GymPlace) throws -> Gym {
        let gym = try gyms.addMapsGym(placeId: place.placeId, name: place.name, address: place.address,
                                      latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
        setCurrentGym(gym.id)
        return gym
    }

    /// "Train here": makes a nearby gym current, saving it first when it is a Maps place.
    func trainHere(_ nearby: NearbyGym) throws {
        switch nearby.target {
        case .saved(let gym): setCurrentGym(gym.id)
        case .place(let place): try chooseMapsGym(place)
        }
    }

    /// The gym within 150 m of `here` that isn't the current one. A failed Maps lookup still finds My gyms.
    func nearbyGym(at here: GymCoordinate) async -> NearbyGym? {
        let places: [GymPlace]
        do { places = try await gymPlaces.nearby(here) }
        catch {
            Self.log.error("Nearby gym search failed: \(error.localizedDescription, privacy: .public)")
            places = []
        }
        let mine: [Gym]
        do { mine = try gyms.gyms() }
        catch {
            Self.log.error("Read gyms failed: \(error.localizedDescription, privacy: .public)")
            mine = []
        }
        return NearbyGymRule.nearest(to: here, currentGymId: currentGym?.id, myGyms: mine, places: places)
    }

    /// Today's "You're at X?": at most every 30 minutes, and only when location is already allowed (no prompt).
    func suggestNearbyGym() async -> NearbyGym? {
        let last = defaults.object(forKey: Self.gymLocationCheckedKey) as? Date
        guard gymLocator.isAuthorized, NearbyGymRule.isDue(lastChecked: last, now: now()) else { return nil }
        defaults.set(now(), forKey: Self.gymLocationCheckedKey)
        guard let here = await gymLocator.locate(askingPermission: false) else { return nil }
        return await nearbyGym(at: here)
    }

    static func makeGymLocator(options: LaunchOptions) -> any GymLocator {
        if let fake = options.fakeLocation { return FakeGymLocator(coordinate: GymCoordinate(latitude: fake.latitude, longitude: fake.longitude)) }
        return options.uiTesting ? UnavailableGymLocator() : CoreLocationGymLocator()
    }

    static func makeGymPlaces(options: LaunchOptions) -> any GymPlaceSearch {
        if options.fakeGymPlaces {
            let origin = options.fakeLocation.map { GymCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
            return FakeGymPlaceSearch(origin: origin ?? GymCoordinate(latitude: 40.0, longitude: -74.0))
        }
        return options.uiTesting ? NoGymPlaceSearch() : MapKitGymPlaceSearch()
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
