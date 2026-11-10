import Foundation
import GymCore
import GymData
import GymSync
import Testing
@testable import GymRollins

/// A real environment over an in-memory store, with its own defaults suite and photo folder.
@MainActor
struct GymTestRig {
    let env: AppEnvironment
    let defaults: UserDefaults
    let photoDir: URL

    var photos: GymPhotoStore { GymPhotoStore(directory: photoDir) }

    static func make(makeSync: (@MainActor (SyncStore, @escaping () -> Date) -> SyncCoordinator)? = nil) throws -> GymTestRig {
        let suite = "GymEnvironmentTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gym-env-photos-\(UUID())")
        let options = LaunchOptions(arguments: ["-uiTesting", "-fixedNow", "2026-10-30T09:00:00Z"])
        let env = try AppEnvironment(options: options, defaults: defaults, gymPhotos: GymPhotoStore(directory: dir),
                                     makeSync: makeSync)
        return GymTestRig(env: env, defaults: defaults, photoDir: dir)
    }

    @discardableResult
    func gym(_ name: String = "Home", _ kinds: [String: ListingLoads] = [:]) throws -> Gym {
        let gym = try env.gyms.addPrivateGym(name: name, address: nil)
        for (kind, loads) in kinds.sorted(by: { $0.key < $1.key }) {
            try env.gyms.addListing(NewListing(gymId: gym.id, kindId: kind, loads: loads))
        }
        return gym
    }

    /// Today shows this routine (a switch for today).
    func switchToday(to routine: Routine) throws {
        env.todayPlanStore.save(try env.todaysPlan().plan.switched(to: routine))
    }

    func routine(_ name: String) throws -> Routine {
        try #require(try env.routines.all().first { $0.name == name })
    }

    func photoCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: photoDir.path())) ?? []).count
    }

    /// A gym with a listing that has a saved photo, and the gym as current.
    func gymWithPhoto() throws -> Gym {
        let name = try photos.save(ProcessedGymPhoto(jpeg: Data("p".utf8), thumbnail: Data("t".utf8)))
        let gym = try env.gyms.addPrivateGym(name: "Photo gym", address: nil)
        try env.gyms.addListing(NewListing(gymId: gym.id, kindId: "dumbbells", photoFile: name))
        env.setCurrentGym(gym.id)
        return gym
    }
}
