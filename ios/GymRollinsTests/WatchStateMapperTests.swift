import Foundation
import GymCore
import GymData
import GymWatchLink
import Testing
@testable import GymRollins

/// What the phone sends the watch for the in-progress workout (plan 17).
@MainActor
@Suite struct WatchStateMapperTests {
    typealias Fixture = WatchSessionActionTests
    let clock = Fixture.Clock()
    let profile = Profile(unit: .lb)

    private func map(_ session: WorkoutSession?, profile: Profile? = nil, claimed: Bool = false) -> WatchWorkout? {
        WatchStateMapper.workout(session: session, now: clock.now, profile: profile ?? self.profile,
                                 exercise: Fixture.lookup, watchRecordsHealth: { _ in claimed })
    }

    @Test func mapsTheNextPlannedSetInTheUsersUnit() throws {
        let lb135 = UnitConverter.toKg(135, from: .lb)
        let s = Fixture.makeSession(clock, entries: [
            WorkoutEntry(exerciseId: "0025", sets: (0..<5).map { _ in WorkoutSet(weightKg: lb135, reps: 8) })
        ])
        s.logNextSet(entryId: s.workout.entries[0].id, weightKg: lb135, reps: 8)
        s.logNextSet(entryId: s.workout.entries[0].id, weightKg: lb135, reps: 8)
        let w = try #require(map(s, claimed: true))
        let next = try #require(w.next)
        #expect(w.id == s.workout.id)
        #expect(w.name == "Push")
        #expect(next.exerciseName == "Barbell Bench Press")
        #expect(next.setLabel == "Set 3/5")
        #expect(next.setDetail == "135 lb × 8")
        #expect(next.setId == s.workout.entries[0].sets[2].id)
        #expect(abs(next.weight - 135) < 0.001)
        #expect(next.reps == 8)
        #expect(next.canLog)
        #expect(w.rest == WatchRest(startedAt: clock.now, endsAt: clock.now.addingTimeInterval(120)))
        #expect(w.watchRecordsHealth)
        #expect(!w.hasPrevious && !w.hasNext)
    }

    @Test func theCrownGridIsThePhonesLoadIncrement() throws {
        let s = Fixture.makeSession(clock)
        let bench = try #require(map(s)?.next)
        let barbell = profile.barbellRounder
        #expect(bench.grid == WatchLoadGrid(unit: .lb, step: barbell.step, offset: barbell.offset))
        s.select(s.workout.entries[2].id)
        let curl = try #require(map(s)?.next)
        #expect(curl.grid == WatchLoadGrid(unit: .lb, step: profile.dumbbellRounder.step, offset: 0))
        let kg = try #require(map(s, profile: Profile(unit: .kg))?.next)
        #expect(kg.grid.unit == .kg)
        #expect(kg.weight == 12)
    }

    @Test func exerciseNavigationFlags() throws {
        let s = Fixture.makeSession(clock)
        let first = try #require(map(s))
        #expect(!first.hasPrevious && first.hasNext)
        s.select(s.workout.entries[1].id)
        let middle = try #require(map(s))
        #expect(middle.hasPrevious && middle.hasNext)
        #expect(middle.next?.canLog == false) // plank: logged on the phone
        #expect(middle.next?.setDetail == "45 s")
    }

    @Test func pausedClockAndDoneWorkout() throws {
        let s = Fixture.makeSession(clock)
        clock.now = clock.now.addingTimeInterval(60)
        s.togglePause()
        let paused = try #require(map(s))
        #expect(paused.pausedAt == clock.now)
        #expect(paused.startedAt == s.workout.startedAt)
        s.markAllDone()
        let done = try #require(map(s))
        #expect(done.next == nil)
        #expect(done.status == "All sets done")
    }

    @Test func nothingWithoutARunningWorkout() throws {
        #expect(map(nil) == nil)
        let s = Fixture.makeSession(clock)
        _ = try s.finish(discardingUndone: true)
        #expect(map(s) == nil)
    }

    @Test func loggedWeightKeepsThePlannedKilogramsWhenUnchanged() {
        let planned = 61.2 // 134.9 lb: the watch shows (and sends back) a rounded value
        let shown = UnitConverter.fromKg(planned, to: .lb)
        #expect(WatchStateMapper.loggedKg(weight: shown, unit: .lb, plannedKg: planned) == planned)
        #expect(abs(WatchStateMapper.loggedKg(weight: 145, unit: .lb, plannedKg: planned)
            - UnitConverter.toKg(145, from: .lb)) < 1e-9)
        #expect(WatchStateMapper.loggedKg(weight: 62.5, unit: .kg, plannedKg: planned) == 62.5)
    }
}
