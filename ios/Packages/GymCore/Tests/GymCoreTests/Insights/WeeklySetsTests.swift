import Foundation
import Testing
@testable import GymCore

struct WeeklySetsTests {
    typealias F = InsightsFixture

    @Test func weekIsMondayToSundayInTheCalendarsTimeZone() {
        let utc = F.utc()
        let week = TrainingWeek.interval(containing: F.date("2026-09-27T23:30:00Z"), calendar: utc) // Sunday
        #expect(week.start == F.date("2026-09-21T00:00:00Z"))
        #expect(week.end == F.date("2026-09-28T00:00:00Z"))
        // 23:30 UTC Sunday is already Monday 01:30 in Warsaw (CEST, UTC+2): next week there.
        let warsaw = TrainingWeek.calendar(timeZone: TimeZone(identifier: "Europe/Warsaw")!)
        let local = TrainingWeek.interval(containing: F.date("2026-09-27T23:30:00Z"), calendar: warsaw)
        #expect(local.start == F.date("2026-09-27T22:00:00Z"))
        // Monday 00:00 in New York belongs to the new week even though UTC still says Monday 04:00.
        let ny = TrainingWeek.calendar(timeZone: TimeZone(identifier: "America/New_York")!)
        #expect(TrainingWeek.interval(containing: F.date("2026-09-28T04:00:00Z"), calendar: ny).start
                == F.date("2026-09-28T04:00:00Z"))
    }

    @Test func weekSpanningDSTChangeIsStillSevenCalendarDays() {
        let warsaw = TrainingWeek.calendar(timeZone: TimeZone(identifier: "Europe/Warsaw")!)
        // DST ends Sun 25 Oct 2026 in Europe: that week is 169 hours long.
        let week = TrainingWeek.interval(containing: F.date("2026-10-24T12:00:00Z"), calendar: warsaw)
        #expect(week.start == F.date("2026-10-18T22:00:00Z"))
        #expect(week.end == F.date("2026-10-25T23:00:00Z"))
    }

    @Test func countsHardSetsWithSecondaryHalfInTheWeekOnly() {
        let now = F.date("2026-09-26T09:00:00Z")
        let week = TrainingWeek.interval(containing: now, calendar: F.utc())
        let workouts = [
            F.workout("2026-09-21T18:00:00Z", [("0025", F.sets(1, warmup: true) + F.sets(3))]), // Mon
            F.workout("2026-09-24T18:00:00Z", [("0198", F.sets(3, rir: 4)), ("0313", F.sets(2))]), // Thu
            F.workout("2026-09-20T18:00:00Z", [("0025", F.sets(5))]),  // previous Sunday: not counted
            F.workout("2026-09-26T08:00:00Z", [("run", F.sets(1, reps: 1, sec: 900))]),
        ]
        let counts = WeeklySets.count(workouts: workouts, exercise: F.lookup, week: week)
        #expect(counts[.chest] == 3)
        #expect(counts[.triceps] == 1.5)
        #expect(counts[.shoulders] == 1.5)
        #expect(counts[.lats] == 3) // effort doesn't discount the set count
        #expect(counts[.biceps] == 3.5) // 2 direct + 3 × 0.5
        #expect(counts[.forearms] == 2.5)
        #expect(counts[.quads] == nil)
    }

    @Test func progressAgainstTargets() {
        let counts: [MuscleGroup: Double] = [.chest: 12, .biceps: 3, .calves: 13]
        let rows = WeeklySets.progress(counts: counts, targets: [.chest: SetTargetRange(min: 10, max: 20)])
        #expect(rows.map(\.group) == MuscleGroup.allCases)
        let byGroup = Dictionary(uniqueKeysWithValues: rows.map { ($0.group, $0) })
        #expect(byGroup[.chest]!.status == .within)
        #expect(byGroup[.biceps]!.status == .below)
        #expect(byGroup[.biceps]!.target == MuscleGroup.biceps.defaultTarget)
        #expect(byGroup[.calves]!.status == .above)
        #expect(byGroup[.quads]!.sets == 0)
        #expect(byGroup[.quads]!.status == .below)
        #expect(byGroup[.chest]!.fraction == 0.6)
    }

    @Test func fractionalContributionsAtTheBoundaryCountAsMet() {
        // A custom upper-legs exercise gives quads 1/3 per set: six 5-set sessions sum to 9.999999999999998 ("10").
        let sets = (0..<6).reduce(0.0) { total, _ in total + 5 * (1.0 / 3) }
        #expect(sets < 10)
        let row = WeeklyMuscleSets(group: .quads, sets: sets, target: SetTargetRange(min: 10, max: 20))
        #expect(row.status == .within)
        #expect(WeeklyMuscleSets(group: .quads, sets: 20.000_000_000_1, target: SetTargetRange(min: 10, max: 20))
                .status == .within)
    }

    @Test func zeroTargetIsNeverBelow() {
        let rows = WeeklySets.progress(counts: [:], targets: [.abs: SetTargetRange(min: 0, max: 0)])
        let abs = rows.first { $0.group == .abs }!
        #expect(abs.status == .within)
        #expect(abs.fraction == 1)
    }

    @Test func setCountFormatting() {
        #expect(WeeklySets.format(12) == "12")
        #expect(WeeklySets.format(3.5) == "3.5")
        #expect(WeeklySets.format(0.25) == "0.3")
        #expect(SetTargetRange(min: 10, max: 20).text == "10\u{2013}20")
        #expect(SetTargetRange(min: 8, max: 8).text == "8")
    }

    @Test func targetRangeValidation() {
        #expect(SetTargetRange(min: 10, max: 20).isValid)
        #expect(SetTargetRange(min: 0, max: 0).isValid)
        #expect(!SetTargetRange(min: 12, max: 10).isValid)
        #expect(!SetTargetRange(min: -1, max: 10).isValid)
        #expect(!SetTargetRange(min: 10, max: 51).isValid)
    }
}
