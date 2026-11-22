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
        _ = try rig.env.todaysPlan()
        #expect(rig.env.gymMatcher() == nil)
        #expect(rig.env.todayGymContext() == nil)
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

    @Test func aDeletedGymCantBecomeCurrent() throws {
        let rig = try GymTestRig.make()
        let kept = try rig.gym("Kept")
        let gone = try rig.gym("Gone")
        rig.env.setCurrentGym(kept.id)
        _ = try rig.env.gyms.deleteGym(gone.id)

        #expect(rig.env.setCurrentGym(gone.id) == false)
        #expect(rig.env.currentGym?.id == kept.id, "the current gym is left alone")
        #expect(rig.defaults.string(forKey: AppEnvironment.currentGymKey) == kept.id.uuidString)

        #expect(throws: GymChoiceError.self) {
            try rig.env.trainHere(NearbyGym(target: .saved(gone), distanceMeters: 20))
        }
        #expect(rig.env.currentGym?.id == kept.id)
        #expect(rig.env.setCurrentGym(kept.id))
        #expect(rig.env.setCurrentGym(nil))
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
        _ = try rig.env.todaysPlan()
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

    /// The app never swaps for the gym (owner, 2026-11-18): at a gym without a barbell (or with nothing listed),
    /// today's plan, a later day's plan and what the watch's "Start today's workout" starts are all the routine.
    @Test func theGymNeverChangesThePlan() throws {
        let rig = try GymTestRig.make()
        let push = try rig.routine("Push + Arms")
        #expect(push.exercises.contains { $0.exerciseId == "0025" }, "the barbell bench press is planned")
        let later = TodayDay(offset: 2).date(now: rig.env.now())
        try rig.env.schedule(every: WeekSchedule.isoWeekday(later), push.id)
        for gym in [try rig.gym("Iron Works Gym", kettlebellGym), try rig.gym("Garage")] {
            rig.env.setCurrentGym(gym.id)
            let matcher = try #require(rig.env.gymMatcher())
            if case .available = matcher.availability(of: "0025") {
                Issue.record("\(gym.name) can't do the barbell bench press")
            }
            try rig.switchToday(to: push)
            let today = try rig.env.todaysPlan().plan
            #expect(today.exercises == push.exercises, Comment(rawValue: gym.name))
            #expect(!today.canSaveToRoutine, Comment(rawValue: gym.name))
            let model = TodayModel.make(plan: today, profile: rig.env.profile, library: rig.env.library,
                                        history: { _ in [] }, gym: rig.env.todayGymContext())
            #expect(model.rows.map(\.exerciseId) == push.exercises.map(\.exerciseId), Comment(rawValue: gym.name))
            #expect(try rig.env.laterDay(on: later).plan.exercises == push.exercises, Comment(rawValue: gym.name))
        }
        #expect(rig.env.startTodaysWorkout())
        let workout = try #require(rig.env.session?.workout)
        #expect(workout.entries.map(\.exerciseId) == push.exercises.map(\.exerciseId))
        #expect(try rig.env.routines.routine(push.id) == push)
    }

    /// A gym with nothing listed still gives Today its context (no loads, no photos), and nothing else changes.
    @Test func aGymWithNothingListedKeepsThePlan() throws {
        let rig = try GymTestRig.make()
        let push = try rig.routine("Push + Arms")
        try rig.switchToday(to: push)
        rig.env.setCurrentGym(try rig.gym("Just added").id)
        #expect(try rig.env.todaysPlan().plan.exercises == push.exercises)
        let context = try #require(rig.env.todayGymContext())
        #expect(push.exercises.allSatisfy { context.loads(for: $0.exerciseId) == nil })
    }

    @Test func startSessionUsesThePlanAndFittedWeights() throws {
        let rig = try GymTestRig.make()
        let heavy = Routine(name: "KB", exercises: [
            RoutineExercise(exerciseId: "0541", sets: 3, reps: 12, repsMin: 10, weightKg: 30),
            RoutineExercise(exerciseId: "0070", sets: 3, reps: 10, repsMin: 8, weightKg: 25),
        ])
        try rig.env.routines.upsert(heavy)
        try rig.switchToday(to: heavy)
        rig.env.setCurrentGym(try rig.gym("Kettlebells", kettlebellGym).id)

        #expect(rig.env.startTodaysWorkout())

        let workout = try #require(rig.env.session?.workout)
        #expect(workout.entries.map(\.exerciseId) == ["0541", "0070"], "the barbell preacher curl stays planned")
        let row = try #require(workout.entries.first)
        #expect(row.sets.allSatisfy { $0.weightKg == 24 }, "30 kg isn't on the shelf: the heaviest bell is 24 kg")
        #expect(workout.routineId == heavy.id)
    }

    @Test func addingAnExerciseMidWorkoutUsesTheGymsWeights() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("KB", ["kettlebells": .fixed(kg: [20, 24])])
        rig.env.setCurrentGym(gym.id)
        let curl = try #require(rig.env.library.exercises.first { $0.equipment == "kettlebell" && $0.mode == .reps })
        let loads = try #require(rig.env.gymLoads(curl.id))
        #expect(loads == .fixed(kg: [20, 24]))
        let workout = Workout(startedAt: rig.env.now().addingTimeInterval(-86_400), name: "Past", entries: [
            WorkoutEntry(exerciseId: curl.id, sets: (0..<3).map { _ in
                WorkoutSet(weightKg: 30, reps: 10).completing(at: rig.env.now().addingTimeInterval(-86_400))
            }),
        ])
        try rig.env.workouts.save(workout, records: [])
        #expect(rig.env.adHocEntry(exerciseId: curl.id).sets.filter { !$0.warmup }.allSatisfy { $0.weightKg == 24 })
    }

    /// Today, plan mode and the watch each call this, so it must stay cheap on the real library.
    @Test func todaysPlanAtAGymForTheWholeSplitIsFast() throws {
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
