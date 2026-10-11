import Foundation
import GymCore
import Testing
@testable import GymData

@Suite struct WeekScheduleTests {
    @Test func isoWeekday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let saturday = Date(timeIntervalSince1970: 1_790_380_800) // 2026-09-26 00:00 UTC
        #expect(WeekSchedule.isoWeekday(saturday, calendar: cal) == 6)
        let push = UUID()
        #expect(WeekSchedule(days: [6: push]).routineId(on: saturday, calendar: cal) == push)
        #expect(WeekSchedule(days: [6: push]).routineId(on: saturday.addingTimeInterval(86_400), calendar: cal) == nil)
    }

    @Test func profileRounders() {
        #expect(Profile().barbellRounder == .barbellLb)
        #expect(Profile().dumbbellRounder == LoadRounder(unit: .lb, step: 2.5))
        #expect(Profile(unit: .kg).barbellRounder == .barbellKg)
        #expect(Profile(unit: .kg, plateInventory: .standardKg).barbellRounder == .barbellKg)
    }

    /// The barbell rounder follows the configured plates: without 2.5 lb plates 135 + 5 suggests 145, not 140.
    @Test func barbellRounderFollowsTheEnabledPlates() {
        let profile = Profile(plateInventory: PlateInventory(unit: .lb, bar: 45, plates: [45, 35, 25, 10, 5]))
        let lb = { UnitConverter.toKg($0, from: .lb) }
        #expect((UnitConverter.fromKg(profile.barbellRounder.nearest(lb(140)), to: .lb) * 100).rounded() / 100 == 145)
    }
}
