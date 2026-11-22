import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Once, after the update, the gym's list learns from every finished workout that has a gym (owner, 2026-11-22).
@MainActor
@Suite struct GymLearningCatchUpTests {
    private static let day: TimeInterval = 86_400
    private static let base: TimeInterval = 1_793_000_000

    private func save(_ rig: GymTestRig, gym: UUID?, daysAgo: Double, exercise: String, kg: Double,
                      finished: Bool = true) throws {
        let start = Date(timeIntervalSince1970: Self.base - daysAgo * Self.day)
        let workout = Workout(startedAt: start, endedAt: finished ? start.addingTimeInterval(3_000) : nil,
                              name: "Workout", entries: [
                                  WorkoutEntry(exerciseId: exercise, sets: [WorkoutSet(weightKg: kg, reps: 10, done: true)]),
                              ], gymId: gym)
        try rig.env.workouts.save(workout)
    }

    /// The launch already ran the catch-up on an empty store; these tests make the update's first launch again.
    private func firstLaunch(_ rig: GymTestRig) {
        rig.defaults.removeObject(forKey: AppEnvironment.gymLearningCatchUpKey)
    }

    private func kinds(_ rig: GymTestRig, _ gym: Gym) throws -> [String] {
        try rig.env.gyms.listings(gymId: gym.id).map(\.item.kindId).sorted()
    }

    @Test func pastWorkoutsAtAGymAddTheirEquipmentAndWeights() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage")
        try save(rig, gym: gym.id, daysAgo: 3, exercise: "0294", kg: 14)
        try save(rig, gym: gym.id, daysAgo: 9, exercise: "0294", kg: 10)
        try save(rig, gym: gym.id, daysAgo: 5, exercise: "0198", kg: 40) // lat pulldown: its first kind
        try save(rig, gym: nil, daysAgo: 6, exercise: "0541", kg: 12) // no gym: not learned
        try save(rig, gym: gym.id, daysAgo: 1, exercise: "1370", kg: 40, finished: false) // not finished

        firstLaunch(rig)
        let revision = rig.env.gymRevision
        rig.env.catchUpGymLearningOnce()

        #expect(try kinds(rig, gym) == ["dumbbells", "lat-pulldown"])
        let dumbbells = try #require(try rig.env.gyms.listings(gymId: gym.id).first { $0.item.kindId == "dumbbells" })
        #expect(dumbbells.loads == .fixed(kg: [10, 14]) && dumbbells.loadsFromWorkouts)
        #expect(rig.env.gymRevision > revision, "screens reload")
        #expect(rig.defaults.bool(forKey: AppEnvironment.gymLearningCatchUpKey))
    }

    /// A listing the owner deleted comes back only when a new workout uses it, not at the next launch.
    @Test func itRunsOnce() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage")
        try save(rig, gym: gym.id, daysAgo: 3, exercise: "0294", kg: 14)
        firstLaunch(rig)
        rig.env.catchUpGymLearningOnce()
        let dumbbells = try #require(try rig.env.gyms.listings(gymId: gym.id).first)
        try rig.env.removeListing(dumbbells.id)

        let revision = rig.env.gymRevision
        rig.env.catchUpGymLearningOnce()

        #expect(try kinds(rig, gym).isEmpty)
        #expect(rig.env.gymRevision == revision)
    }

    @Test func aMarkerFromAnEarlierLaunchStopsIt() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Garage")
        try save(rig, gym: gym.id, daysAgo: 3, exercise: "0294", kg: 14)
        rig.defaults.set(true, forKey: AppEnvironment.gymLearningCatchUpKey)

        rig.env.catchUpGymLearningOnce()

        #expect(try kinds(rig, gym).isEmpty)
    }

    @Test func withoutAUsableCatalogueItTriesAgainAtTheNextStart() throws {
        let rig = try GymTestRig.make(gymCatalog: .unavailable)
        let gym = try rig.gym("Garage")
        try save(rig, gym: gym.id, daysAgo: 3, exercise: "0294", kg: 14)
        #expect(!rig.defaults.bool(forKey: AppEnvironment.gymLearningCatchUpKey), "the launch didn't set it either")

        rig.env.catchUpGymLearningOnce()

        #expect(try kinds(rig, gym).isEmpty)
        #expect(!rig.defaults.bool(forKey: AppEnvironment.gymLearningCatchUpKey))
    }

    @Test func noWorkoutsAtAGymStillSetsTheMarker() throws {
        let rig = try GymTestRig.make()
        firstLaunch(rig)
        rig.env.catchUpGymLearningOnce()
        #expect(rig.defaults.bool(forKey: AppEnvironment.gymLearningCatchUpKey))
    }

    /// Each gym learns from its own workouts only.
    @Test func eachGymLearnsOnlyFromItsOwnWorkouts() throws {
        let rig = try GymTestRig.make()
        let garage = try rig.gym("Garage")
        let basement = try rig.gym("Basement")
        try save(rig, gym: garage.id, daysAgo: 3, exercise: "0294", kg: 14)
        try save(rig, gym: basement.id, daysAgo: 2, exercise: "1269", kg: 30)
        try save(rig, gym: basement.id, daysAgo: 1, exercise: "0541", kg: 12)

        firstLaunch(rig)
        rig.env.catchUpGymLearningOnce()

        #expect(try kinds(rig, garage) == ["dumbbells"])
        #expect(try kinds(rig, basement) == ["cable-station", "kettlebells"])
    }

    /// The launch runs it (`AppEnvironment.init`), before any screen reads the gyms: a phone updated with a gym and a
    /// workout in its store has the gym's equipment right after the start.
    @Test func theLaunchRunsIt() throws {
        let suite = "GymLearningCatchUpTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gym-catchup-photos-\(UUID())")
        let photos = GymPhotoStore(directory: dir)
        var gymId: UUID?
        do {
            let before = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-diskStore", "-resetStore"]),
                                            defaults: defaults, gymPhotos: photos)
            let gym = try before.gyms.addPrivateGym(name: "Garage", address: nil)
            gymId = gym.id
            let start = Date(timeIntervalSince1970: Self.base)
            try before.workouts.save(Workout(startedAt: start, endedAt: start.addingTimeInterval(3_000), name: "Workout",
                                             entries: [WorkoutEntry(exerciseId: "0294", sets: [
                                                 WorkoutSet(weightKg: 14, reps: 10, done: true)])], gymId: gym.id))
            #expect(try before.gyms.listings(gymId: gym.id).isEmpty)
        }
        defaults.removeObject(forKey: AppEnvironment.gymLearningCatchUpKey) // the update's first launch
        let after = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-diskStore"]),
                                       defaults: defaults, gymPhotos: photos)
        let listings = try after.gyms.listings(gymId: try #require(gymId))
        #expect(listings.map(\.item.kindId) == ["dumbbells"])
        #expect(listings.first?.loads == .fixed(kg: [14]))
        #expect(defaults.bool(forKey: AppEnvironment.gymLearningCatchUpKey))
    }
}
