import Foundation
import GymCore
import GymData
import GymSync
import Testing
@testable import GymRollins

@MainActor
@Suite struct GymBuildEnvironmentTests {
    private func build(_ env: AppEnvironment, avoid: [String] = []) -> BuiltWorkout? {
        env.buildWorkout(muscles: [.chest], length: .short, avoid: avoid)
    }

    @Test func buildWorkoutUsesTheCurrentGym() throws {
        let rig = try GymTestRig.make()
        #expect(build(rig.env) == nil, "no gym, nothing to build from")
        let kb = try rig.gym("KB", kettlebellGym)
        let rich = try rig.gym("Rich", richGym)
        for gym in [kb, rich] {
            rig.env.setCurrentGym(gym.id)
            let matcher = try #require(rig.env.gymMatcher(gymId: gym.id))
            let built = try #require(build(rig.env))
            for item in built.items {
                if case .missing = matcher.availability(of: item.exercise.exerciseId) {
                    Issue.record("\(gym.name): \(item.exercise.exerciseId) isn't doable here")
                }
            }
        }
        #expect(try #require(build(rig.env)).items.count == 3)
    }

    @Test func loggedCountsAndPreferencesReachTheBuilder() throws {
        let rig = try GymTestRig.make()
        let env = rig.env
        env.setCurrentGym(try rig.gym("Rich", richGym).id)
        let baseline = try #require(build(env)).items.map(\.exercise.exerciseId)
        #expect(baseline.count == 3)

        try env.setPreference(.never, for: baseline[0])
        #expect(!(try #require(build(env)).items.map(\.exercise.exerciseId).contains(baseline[0])))
        try env.setPreference(.normal, for: baseline[0])

        // Workouts dated after today count as logged without making the exercise "recent".
        let matcher = try #require(env.gymMatcher())
        // A free-weight exercise that needs equipment, so the builder's per-machine cap can't keep it out.
        let doable = env.library.exercises.filter { exercise in
            guard exercise.mode == .reps, !baseline.contains(exercise.id),
                  MuscleTaxonomy.contributions(for: exercise).contains(where: {
                      $0.isPrimary && BuildMuscle.chest.groups.contains($0.group)
                  }),
                  case let .available(match) = matcher.availability(of: exercise.id) else { return false }
            return !match.listingIds.isEmpty && match.listingIds.allSatisfy { matcher.listing($0).flatMap { matcher.kind($0.kindId) }?.isMachine == false }
        }
        let favourite = try #require(doable.first)
        let future = env.now().addingTimeInterval(86_400)
        for day in 0..<6 {
            try env.workouts.save(Workout(startedAt: future.addingTimeInterval(Double(day)), endedAt: future.addingTimeInterval(Double(day) + 60),
                                          name: "Chest", entries: [WorkoutEntry(exerciseId: favourite.id, sets: [
                                              WorkoutSet(weightKg: 20, reps: 10, done: true, completedAt: future)])]))
        }
        #expect(env.gymLoggedCounts()[favourite.id] == 6)
        let after = try #require(build(env)).items.map(\.exercise.exerciseId)
        #expect(after.contains(favourite.id), "fav=\(favourite.id) \(favourite.name) doable=\(doable.count) base=\(baseline) after=\(after)")
    }

    @Test func rebuildAvoidListGrows() throws {
        let rig = try GymTestRig.make()
        rig.env.setCurrentGym(try rig.gym("Rich", richGym).id)
        var avoid: [String] = []
        var seen: Set<String> = []
        for _ in 0..<3 {
            let ids = try #require(build(rig.env, avoid: avoid)).items.map(\.exercise.exerciseId)
            #expect(seen.isDisjoint(with: ids), "Rebuild shows new exercises while there are some")
            seen.formUnion(ids)
            avoid += ids
        }
        #expect(avoid.count == 9)
    }
}

@MainActor
@Suite struct GymWipeEnvironmentTests {
    private func addGym(_ rig: GymTestRig) throws -> String {
        let gym = try rig.gymWithPhoto()
        #expect(try rig.env.gyms.gym(gym.id) != nil)
        #expect(rig.photoCount() == 2)
        return gym.id.uuidString
    }

    @Test func eraseAllRemovesGymsAndPhotos() throws {
        let rig = try GymTestRig.make()
        _ = try addGym(rig)
        try rig.env.eraseAllLocalData()
        #expect(try rig.env.gyms.gyms().isEmpty)
        #expect(rig.photoCount() == 0)
        #expect(rig.env.currentGym == nil)
        #expect(rig.defaults.object(forKey: AppEnvironment.currentGymKey) == nil)
    }

    @Test func localResetRemovesGymsAndPhotos() async throws {
        let rig = try GymTestRig.make()
        _ = try addGym(rig)
        try await rig.env.sync.signOutAndRemoveLocalData()
        #expect(try rig.env.gyms.gyms().isEmpty)
        #expect(rig.photoCount() == 0)
        #expect(rig.env.currentGym == nil)
        #expect(rig.defaults.object(forKey: AppEnvironment.currentGymKey) == nil)
    }

    @Test func plainSignOutKeepsThem() async throws {
        let rig = try GymTestRig.make()
        let id = try addGym(rig)
        try await rig.env.sync.cancelAccountSwitch() // signs out without removing the local copy
        #expect(try rig.env.gyms.gyms().count == 1)
        #expect(rig.photoCount() == 2)
        #expect(rig.defaults.string(forKey: AppEnvironment.currentGymKey) == id)
    }
}
