import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Build workout against the real bundled library and a real environment (spec criteria 1 and 3), not fixtures.
@MainActor
@Suite struct BuildWorkoutScenarioTests {
    private let day: TimeInterval = 86_400

    private func photographed(_ rig: GymTestRig, _ name: String, _ kinds: [String: ListingLoads]) throws -> Gym {
        let gym = try rig.env.gyms.addPrivateGym(name: name, address: nil)
        for (kind, loads) in kinds.sorted(by: { $0.key < $1.key }) {
            let file = try rig.photos.save(ProcessedGymPhoto(jpeg: Data(kind.utf8), thumbnail: Data(kind.utf8)))
            try rig.env.gyms.addListing(NewListing(gymId: gym.id, kindId: kind, loads: loads, photoFile: file))
        }
        return gym
    }

    private func model(_ env: AppEnvironment, _ built: BuiltWorkout, muscles: [BuildMuscle], length: BuildLength,
                       gymName: String) -> BuildResultModel {
        BuildResultModel.make(built: built, muscles: muscles, length: length, gymName: gymName, gym: env.todayGymContext(),
                              profile: env.profile, library: env.library,
                              history: { (try? env.workouts.history(exerciseId: $0, limit: 5)) ?? [] })
    }

    /// Equipment exercises for these chips that the current gym can do.
    private func offeredIds(_ env: AppEnvironment, _ muscles: [BuildMuscle]) throws -> [String] {
        let matcher = try #require(env.gymMatcher())
        let groups = Set(muscles.flatMap { $0.groups })
        return env.library.exercises.filter { exercise in
            guard exercise.mode == .reps,
                  MuscleTaxonomy.contributions(for: exercise).contains(where: { $0.isPrimary && groups.contains($0.group) }),
                  case let .available(match) = matcher.availability(of: exercise.id) else { return false }
            return !match.listingIds.isEmpty
        }.map(\.id)
    }

    private func offered(_ env: AppEnvironment, _ muscles: [BuildMuscle]) throws -> Int {
        try offeredIds(env, muscles).count
    }

    /// Marks exactly `slots` exercises "More often", so they rank first every day: only finishing a workout (which
    /// saves it) can make the builder move on from them.
    private func favouriteTheFirst(_ slots: Int, _ muscles: [BuildMuscle], _ env: AppEnvironment) throws -> Set<String> {
        let favourites = Set(try offeredIds(env, muscles).sorted().prefix(slots))
        for id in favourites { try env.setPreference(.more, for: id) }
        return favourites
    }

    /// Starts the built workout on `date`, does every set and finishes it: a finished workout with hard sets.
    private func complete(_ built: BuiltWorkout, on date: Date, _ env: AppEnvironment) throws {
        let routine = Routine(name: "Built", exercises: built.items.map(\.exercise))
        let started = SessionPlanner.start(routine: routine, profile: env.profile, library: env.library, now: date,
                                           history: { (try? env.workouts.history(exerciseId: $0, limit: 5)) ?? [] },
                                           autoWarmups: false, loads: env.gymLoadsLookup())
        let finished = started.markingAllDone(at: date).finished(at: date.addingTimeInterval(3_000), discardingUndone: true)
        #expect(finished.entries.count == built.items.count)
        #expect(finished.entries.flatMap(\.sets).allSatisfy(HardSets.isHard), "every set counts as a hard set")
        try env.workouts.save(finished)
    }

    /// Builds, does and finishes the workout on four days in a row.
    private func fourDays(_ rig: GymTestRig, _ muscles: [BuildMuscle], _ length: BuildLength) throws -> [[String]] {
        let start = rig.env.now()
        var days: [[String]] = []
        for index in 0..<4 {
            let date = start.addingTimeInterval(Double(index) * day)
            let built = try #require(rig.env.buildWorkout(muscles: muscles, length: length, avoid: [], date: date))
            days.append(built.items.map(\.exercise.exerciseId))
            try complete(built, on: date, rig.env)
        }
        return days
    }

    private func expectHalfChanges(_ days: [[String]], _ label: String) {
        for index in 1..<days.count {
            let fresh = days[index].filter { !days[index - 1].contains($0) }.count
            #expect(!days[index].isEmpty, "\(label) day \(index + 1) has exercises")
            #expect(fresh * 2 >= days[index].count,
                    "\(label) day \(index + 1): \(fresh) of \(days[index].count) are new: \(days[index - 1]) -> \(days[index])")
        }
    }

    // MARK: Criterion 1

    @Test func newGymFiveListingsBuildChest() throws {
        let rig = try GymTestRig.make()
        let gym = try photographed(rig, "Garage", [
            "dumbbells": .fixed(kg: [10, 20, 30]), "barbell": .plates, "flat-bench": .none,
            "cable-station": .stack(maxKg: 80, stepKg: 5), "pull-up-bar": .none,
        ])
        rig.env.setCurrentGym(gym.id)
        let built = try #require(rig.env.buildWorkout(muscles: [.chest], length: .medium, avoid: []))
        #expect(!built.items.isEmpty)
        let matcher = try #require(rig.env.gymMatcher())
        let listings = try rig.env.gyms.listings(gymId: gym.id)
        let listedKinds = Set(listings.map(\.item.kindId))
        let rows = model(rig.env, built, muscles: [.chest], length: .medium, gymName: "Garage").rows
        #expect(rows.count == built.items.count)
        for (item, row) in zip(built.items, rows) {
            let id = item.exercise.exerciseId
            guard case .available = matcher.availability(of: id) else {
                Issue.record("\(id) isn't doable at this gym")
                continue
            }
            if item.isBodyweightFill {
                #expect(matcher.needsNoEquipment(id), "\(id) is marked as a fill but needs equipment")
                #expect(row.mark == .noEquipment, "\(id) must say \"no equipment\"")
                continue
            }
            #expect(row.mark != .noEquipment)
            #expect(!item.match.listingIds.isEmpty, "\(id) names the item it uses")
            for listingId in item.match.listingIds {
                let listing = listings.first { $0.id == listingId }
                #expect(listing?.photoFile != nil, "\(id): listing \(listingId) has a photo")
            }
            #expect(row.photoFile != nil, "\(id) shows its listing's photo")
            for group in try #require(rig.env.gymCatalog.requirements.requirement(for: id)) {
                #expect(!listedKinds.isDisjoint(with: group), "\(id) needs one of \(group), which isn't listed here")
            }
        }
    }

    // MARK: Criterion 3

    @Test func fourDaysInARow() throws {
        let rig = try GymTestRig.make()
        let rich = try rig.gym("Rich", richGym)
        rig.env.setCurrentGym(rich.id)
        let slots = BuildLength.medium.slots(muscleCount: 1)
        let chestOffered = try offered(rig.env, [.chest])
        #expect(chestOffered >= 2 * slots, "the rich gym offers \(chestOffered) chest exercises for \(slots) slots")
        let favourites = try favouriteTheFirst(slots, [.chest], rig.env)
        let days = try fourDays(rig, [.chest], .medium)
        #expect(Set(days[0]) == favourites, "day 1 starts with the exercises marked More often: \(days[0])")
        expectHalfChanges(days, "Rich chest")
    }

    /// The owner's real gym (`-seedGym`): kettlebells and a flat bench, building Arms.
    @Test func fourDaysInARowAtHomeForArms() throws {
        let rig = try GymTestRig.make()
        let home = try DebugGymSeed.apply(context: rig.env.container.mainContext, now: rig.env.now())
        rig.env.setCurrentGym(home.id)
        let slots = BuildLength.medium.slots(muscleCount: 1)
        let armsOffered = try offered(rig.env, [.arms])
        #expect(armsOffered >= 2 * slots, "Home offers \(armsOffered) arm exercises for \(slots) slots")
        let favourites = try favouriteTheFirst(slots, [.arms], rig.env)
        let days = try fourDays(rig, [.arms], .medium)
        #expect(Set(days[0]) == favourites, "day 1 starts with the exercises marked More often: \(days[0])")
        expectHalfChanges(days, "Home arms")
    }

    @Test func rebuildAlwaysChangesWhileThereIsMore() throws {
        let rig = try GymTestRig.make()
        rig.env.setCurrentGym(try rig.gym("Rich", richGym).id)
        let env = rig.env
        let run = BuildRun { avoid in env.buildWorkout(muscles: [.chest], length: .short, avoid: avoid) }
        run.build()
        var previous = Set(run.exerciseIds)
        #expect(previous.count == 3)
        var seen = previous
        // Rebuild can only show new exercises while the gym has more of them.
        let taps = min(6, try offered(env, [.chest]) / 3 - 1)
        #expect(taps >= 2)
        for tap in 1...taps {
            run.rebuild()
            let now = Set(run.exerciseIds)
            #expect(now != previous && now.isDisjoint(with: previous), "tap \(tap) shows something new: \(previous) -> \(now)")
            seen.formUnion(now)
            previous = now
        }
        #expect(seen.count == 3 * (taps + 1), "every tap showed a workout none of the earlier ones had")
        #expect(run.avoidIds.count == 3 * taps)
    }

    // MARK: Start

    @Test func startBecomesTodaysPlan() throws {
        let rig = try GymTestRig.make()
        let env = rig.env
        env.setCurrentGym(try rig.gym("Rich", richGym).id)
        let routinesBefore = try env.routines.all()
        let scheduled = try env.todaysPlan().plan
        #expect(scheduled.kind != .built)

        let built = try #require(env.buildWorkout(muscles: [.chest, .arms], length: .medium, avoid: []))
        let items = built.items.map(\.exercise)
        env.todayPlanStore.save(TodayPlan.built(name: "Chest + Arms", items: items, day: TodayPlan.dayKey(env.now())))

        let plan = try env.todaysPlan().plan
        #expect(plan.kind == .built)
        #expect(plan.title == "Chest + Arms")
        #expect(plan.exercises.map(\.exerciseId) == items.map(\.exerciseId))
        #expect(try env.routines.all() == routinesBefore, "the routine isn't changed")

        #expect(env.startTodaysWorkout())
        let workout = try #require(env.session?.workout)
        #expect(workout.name == "Chest + Arms")
        #expect(workout.entries.map(\.exerciseId) == items.map(\.exerciseId))

        let after = try env.todaysPlan().plan
        #expect(after.kind == scheduled.kind, "Start clears the plan: Today is back to the schedule")
        #expect(after.title == scheduled.title)
    }
}
