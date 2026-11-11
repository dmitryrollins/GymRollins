import Foundation
import GymCore
import Testing
@testable import GymRollins

/// The owner's changes to later days (owner, 2026-11-10): one `TodayPlan` per date, under the rules today's stored plan
/// follows, taken on the day.
@Suite struct LaterDayPlanStoreTests {
    private let monday = "2026-09-28"

    private func routine(_ name: String, _ ids: [String]) -> Routine {
        Routine(name: name, exercises: ids.map { RoutineExercise(exerciseId: $0, sets: 3, reps: 8) })
    }

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "LaterDayPlanStoreTests.\(UUID())"))
    }

    @Test func aDatesChangeIsKeptForThatDateOnly() throws {
        let store = LaterDayPlanStore(defaults: try defaults())
        let push = routine("Push", ["0025", "0027"])
        let edited = TodayPlan.make(scheduled: push, routines: [push], lastDone: [:], day: monday)
            .deleting(push.exercises[0].id)
        store.save(edited)

        #expect(store.plan(day: monday, routines: [push], scheduled: push.id) == edited)
        #expect(store.plan(day: "2026-09-29", routines: [push], scheduled: push.id) == nil)
        #expect(store.days() == [monday])
    }

    @Test func theRulesOfTodaysStoredPlanApply() throws {
        let store = LaterDayPlanStore(defaults: try defaults())
        let push = routine("Push", ["0025"]), pull = routine("Pull", ["0027"])
        let switched = TodayPlan.make(scheduled: push, routines: [push, pull], lastDone: [:], day: monday).switched(to: pull)
        store.save(switched)
        #expect(store.plan(day: monday, routines: [push], scheduled: push.id) == nil, "its workout was deleted")

        let edited = TodayPlan.make(scheduled: push, routines: [push], lastDone: [:], day: monday)
            .deleting(push.exercises[0].id)
        store.save(edited)
        #expect(store.plan(day: monday, routines: [push, pull], scheduled: pull.id) == nil,
                "Monday now trains another workout: a change to the old one is dropped")
    }

    @Test func takingTheDayRemovesItAndEveryEarlierDay() throws {
        let store = LaterDayPlanStore(defaults: try defaults())
        let push = routine("Push", ["0025"])
        let sunday = TodayPlan.make(scheduled: nil, routines: [], lastDone: [:], day: "2026-09-27").switched(to: push)
        let monday = TodayPlan.make(scheduled: nil, routines: [], lastDone: [:], day: self.monday).switched(to: push)
        let tuesday = TodayPlan.make(scheduled: nil, routines: [], lastDone: [:], day: "2026-09-29").switched(to: push)
        [sunday, monday, tuesday].forEach(store.save)

        #expect(store.take(day: self.monday) == monday)
        #expect(store.days() == ["2026-09-29"])
        #expect(store.take(day: self.monday) == nil)
    }

    @Test func removeAndClear() throws {
        let store = LaterDayPlanStore(defaults: try defaults())
        let push = routine("Push", ["0025"])
        store.save(TodayPlan.make(scheduled: nil, routines: [], lastDone: [:], day: monday).switched(to: push))
        store.remove(day: monday)
        #expect(store.days().isEmpty)
        store.save(TodayPlan.make(scheduled: nil, routines: [], lastDone: [:], day: monday).switched(to: push))
        store.clear()
        #expect(store.days().isEmpty)
    }

    @Test func anAgentsSwitchForADateCanBeRemovedWhateverItPicks() throws {
        let planned = PlannedSwitchStore(defaults: try defaults())
        planned.set(UUID(), on: monday)
        planned.remove(day: monday)
        #expect(planned.all().isEmpty)
    }
}
