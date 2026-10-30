import Foundation
import GymCore
import GymData
import GymSync
import Testing
@testable import GymRollins

let kettlebells: ListingLoads = .fixed(kg: [20, 24])
let kettlebellGym: [String: ListingLoads] = ["kettlebells": kettlebells, "flat-bench": .none]
let richGym: [String: ListingLoads] = [
    "dumbbells": .fixed(kg: [10, 20, 30]), "barbell": .plates, "flat-bench": .none, "adjustable-bench": .none,
    "cable-station": .stack(maxKg: 80, stepKg: 5), "chest-press-machine": .stack(maxKg: 90, stepKg: 5),
    "pec-deck": .stack(maxKg: 80, stepKg: 5), "smith-machine": .plates, "power-rack": .none, "pull-up-bar": .none,
]

@MainActor
@Suite struct GymEnvironmentTests {
    @Test func noCurrentGymChangesNothing() throws {
        let rig = try GymTestRig.make()
        let plan = try rig.env.todaysPlan().plan
        #expect(plan.gymSwaps.isEmpty)
        #expect(plan == plan.adapted(by: nil))
        #expect(rig.env.gymMatcher() == nil)
        #expect(rig.env.gymAdapter() == nil)
        #expect(rig.env.gymLoads("0541") == nil)
    }

    @Test func currentGymPersists() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym()
        rig.env.setCurrentGym(gym.id)
        #expect(rig.env.currentGym?.id == gym.id)
        #expect(rig.defaults.string(forKey: AppEnvironment.currentGymKey) == gym.id.uuidString)
        rig.env.setCurrentGym(nil)
        #expect(rig.env.currentGym == nil)
        #expect(rig.defaults.object(forKey: AppEnvironment.currentGymKey) == nil)
    }

    @Test func deletingTheCurrentGymClearsIt() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gymWithPhoto()
        #expect(rig.photoCount() == 2)
        try rig.env.deleteGym(gym.id)
        #expect(rig.env.currentGym == nil)
        #expect(rig.defaults.object(forKey: AppEnvironment.currentGymKey) == nil)
        #expect(rig.photoCount() == 0)
        let other = try rig.gym("Other")
        let current = try rig.gym("Current")
        rig.env.setCurrentGym(current.id)
        try rig.env.deleteGym(other.id)
        #expect(rig.env.currentGym?.id == current.id, "deleting another gym keeps the current one")
    }

    @Test func aCurrentIdWithNoRowReadsAsNil() throws {
        let rig = try GymTestRig.make()
        rig.defaults.set(UUID().uuidString, forKey: AppEnvironment.currentGymKey)
        #expect(rig.env.currentGym == nil)
        #expect(rig.env.gymMatcher() == nil)
        rig.defaults.set("not a uuid", forKey: AppEnvironment.currentGymKey)
        #expect(rig.env.currentGym == nil)
        #expect(try rig.env.todaysPlan().plan.gymSwaps.isEmpty)
    }

    @Test func changingTheGymReloadsTodayAndTheWatchWithoutSyncing() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym()
        let plan = rig.env.planRevision, today = rig.env.todayPlanRevision
        rig.env.setCurrentGym(gym.id)
        #expect(rig.env.planRevision == plan + 1)
        #expect(rig.env.todayPlanRevision == today + 1)
        let revision = rig.env.gymRevision
        rig.env.gymsChanged()
        #expect(rig.env.gymRevision == revision + 1)
        #expect(rig.env.planRevision == plan + 2)
        #expect(rig.env.todayPlanRevision == today + 2)
    }

    @Test func todaysPlanIsAdapted() throws {
        let rig = try GymTestRig.make()
        let push = try rig.routine("Push + Arms")
        try rig.switchToday(to: push)
        rig.env.setCurrentGym(try rig.gym("Kettlebells", kettlebellGym).id)

        let plan = try rig.env.todaysPlan().plan
        #expect(!plan.gymSwaps.isEmpty)
        #expect(plan.plannedExercises == push.exercises)
        #expect(!plan.exercises.map(\.exerciseId).contains("0025"), "a barbell bench press isn't doable here")
        #expect(!plan.canSaveToRoutine, "a swap isn't an edit, so Save to routine isn't offered")
        #expect(try rig.env.routines.routine(push.id) == push)
        rig.env.setCurrentGym(nil)
        #expect(try rig.env.todaysPlan().plan.exercises == push.exercises)
    }

    @Test func startSessionUsesSwapsAndFittedWeights() throws {
        let rig = try GymTestRig.make()
        let heavy = Routine(name: "KB", exercises: [
            RoutineExercise(exerciseId: "0541", sets: 3, reps: 12, repsMin: 10, weightKg: 30),
            RoutineExercise(exerciseId: "0070", sets: 3, reps: 10, repsMin: 8, weightKg: 25),
        ])
        try rig.env.routines.upsert(heavy)
        try rig.switchToday(to: heavy)
        rig.env.setCurrentGym(try rig.gym("Kettlebells", kettlebellGym).id)
        let plan = try rig.env.todaysPlan().plan
        #expect(plan.gymSwaps.count == 1, "the barbell preacher curl can't be done here")

        #expect(rig.env.startTodaysWorkout())

        let workout = try #require(rig.env.session?.workout)
        #expect(workout.entries.map(\.exerciseId) == plan.exercises.map(\.exerciseId))
        let row = try #require(workout.entries.first)
        #expect(row.sets.allSatisfy { $0.weightKg == 24 }, "30 kg isn't on the shelf: the heaviest bell is 24 kg")
        #expect(workout.routineId == heavy.id)
    }

    @Test func everyAdaptedExerciseIsBackedByListings() throws {
        let rig = try GymTestRig.make()
        let gyms = [try rig.gym("KB", kettlebellGym), try rig.gym("Rich", richGym), try rig.gym("Empty")]
        for gym in gyms {
            rig.env.setCurrentGym(gym.id)
            let matcher = try #require(rig.env.gymMatcher())
            for routine in try rig.env.routines.all() where !routine.exercises.isEmpty {
                try rig.switchToday(to: routine)
                let plan = try rig.env.todaysPlan().plan
                for item in plan.exercises {
                    switch matcher.availability(of: item.exerciseId) {
                    case let .available(match):
                        #expect(match.listingIds.allSatisfy { matcher.listing($0) != nil }, "\(gym.name) \(item.exerciseId)")
                    case .unmapped: break
                    case .missing:
                        #expect(plan.gymSwaps[item.id] == nil, "a swap must land on something the gym has: \(item.exerciseId)")
                    }
                }
            }
        }
    }

    /// Today, plan mode and the watch each call this, so it must stay cheap on the real library.
    @Test func adaptingTheWholeSplitIsFast() throws {
        let rig = try GymTestRig.make()
        rig.env.setCurrentGym(try rig.gym("KB", kettlebellGym).id)
        let routines = try rig.env.routines.all().filter { !$0.exercises.isEmpty }
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            for routine in routines {
                try rig.switchToday(to: routine)
                _ = try rig.env.todaysPlan()
            }
        }
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }
}
