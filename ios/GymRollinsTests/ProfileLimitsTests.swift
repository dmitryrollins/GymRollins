import Foundation
import GymData
import Testing
@testable import GymRollins

@Suite struct ProfileLimitsTests {
    @Test func settingsUpdatesKeepTheNotesEndDate() {
        let until = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 26))
        let p = Profile(limits: "Knee", limitsUntil: until)
        #expect(p.with(deloadPct: 0.1).limitsUntil == until)
        #expect(p.with(restSec: 90, warmupRestSec: 45).limitsUntil == until)
        #expect(p.withStandardEquipment(for: .kg).limitsUntil == until)
    }

    /// Plan 32: Settings and onboarding rebuild the profile; Add workouts must come through as it was.
    @Test func settingsUpdatesKeepAddWorkouts() {
        let p = Profile(mcpLogWorkouts: true)
        #expect(p.with(deloadPct: 0.1).mcpLogWorkouts)
        #expect(p.with(restSec: 90, warmupRestSec: 45).mcpLogWorkouts)
        #expect(p.withStandardEquipment(for: .kg).mcpLogWorkouts)
        #expect(p.with(mcpLogWorkouts: false).mcpLogWorkouts == false)
        #expect(!Profile().with(restSec: 90).mcpLogWorkouts)
    }
}
