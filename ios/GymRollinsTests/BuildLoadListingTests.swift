import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Two cable stations with different stacks: the exercise the builder moves off the first one (its two-per-machine
/// cap) must show, and start with, the weight of the station it was moved to.
@MainActor
@Suite struct BuildLoadListingTests {
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func twoStationRig() throws -> GymTestRig {
        let rig = try GymTestRig.make()
        let gym = try rig.env.gyms.addPrivateGym(name: "Stations", address: nil)
        for max in [40.0, 90.0] {
            try rig.env.gyms.addListing(NewListing(gymId: gym.id, kindId: "cable-station", loads: .stack(maxKg: max, stepKg: nil)))
        }
        rig.env.setCurrentGym(gym.id)
        return rig
    }

    private func logged60(_ rig: GymTestRig, _ built: BuiltWorkout) throws {
        for (offset, item) in built.items.enumerated() {
            let at = rig.env.now().addingTimeInterval(-86_400 * Double(offset + 1))
            let sets = (0..<3).map { _ in WorkoutSet(weightKg: 60, reps: 10).completing(at: at) }
            try rig.env.workouts.save(Workout(startedAt: at, endedAt: at.addingTimeInterval(60), name: "Past",
                                              entries: [WorkoutEntry(exerciseId: item.exercise.exerciseId, sets: sets)]),
                                      records: [])
        }
    }

    @Test func aMovedExerciseShowsAndStartsWithItsOwnStationsWeight() throws {
        let rig = try twoStationRig()
        let env = rig.env
        let matcher = try #require(env.gymMatcher())
        let built = try #require(env.buildWorkout(muscles: [.back, .arms, .chest, .shoulders], length: .long, avoid: []))
        let stationItems = built.items.filter { item in
            item.match.loadListingId.flatMap { matcher.listing($0)?.kindId } == "cable-station"
        }
        let moved = stationItems.filter { item in
            guard case let .available(first) = matcher.availability(of: item.exercise.exerciseId) else { return false }
            return first.loadListingId != item.match.loadListingId
        }
        try #require(!moved.isEmpty, "the builder moved a cable exercise to the other station")
        try logged60(rig, built)

        func expectedKg(_ item: BuiltItem) throws -> Double {
            let listing = try #require(item.match.loadListingId.flatMap { matcher.listing($0) })
            guard case let .stack(maxKg, _) = listing.loads else { throw CocoaError(.fileReadUnknown) }
            // The progression's own weight for the 60 kg history (rounded to its plates), capped by the stack.
            let planned = item.exercise
            let plain = SessionPlanner.suggestion(for: planned, policy: planned.policy ?? .double, profile: env.profile,
                                                  exercise: env.library.exercise(planned.exerciseId),
                                                  history: try env.workouts.history(exerciseId: planned.exerciseId, limit: 5))
            return min(plain.weightKg, maxKg)
        }

        let model = BuildResultModel.make(built: built, muscles: [.back, .arms, .chest, .shoulders], length: .long,
                                          gymName: "Stations", gym: env.todayGymContext(), profile: env.profile,
                                          library: env.library,
                                          history: { (try? env.workouts.history(exerciseId: $0, limit: 5)) ?? [] })
        for item in stationItems {
            let row = try #require(model.rows.first { $0.exerciseId == item.exercise.exerciseId })
            let shown = WeightFormatter.format(kg: try expectedKg(item), unit: env.profile.unit)
            #expect(row.subtitle.contains(shown), "\(item.exercise.exerciseId): \(row.subtitle) should hold \(shown)")
        }

        let started = BuiltStart(name: "Cables", built: built)
        env.todayPlanStore.save(TodayPlan.built(name: started.name, items: started.items, day: TodayPlan.dayKey(env.now()),
                                                listings: started.listings))
        #expect(env.startTodaysWorkout())
        let workout = try #require(env.session?.workout)
        for item in stationItems {
            let entry = try #require(workout.entries.first { $0.exerciseId == item.exercise.exerciseId })
            let want = try expectedKg(item)
            #expect(entry.sets.filter { !$0.warmup }.allSatisfy { $0.weightKg == want },
                    "\(item.exercise.exerciseId) should start at \(want) kg: \(entry.sets.map(\.weightKg))")
        }
    }

    @Test func theLoadListingsSurviveStoringThePlan() throws {
        let id = UUID()
        let plan = TodayPlan.built(name: "B", items: [RoutineExercise(exerciseId: "x", sets: 3, reps: 8)], day: "d",
                                   listings: ["x": id])
        let decoded = try JSONDecoder().decode(TodayPlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded.builtListings == ["x": id])
        #expect(plan.adapted(by: nil).builtListings == ["x": id])
    }
}
