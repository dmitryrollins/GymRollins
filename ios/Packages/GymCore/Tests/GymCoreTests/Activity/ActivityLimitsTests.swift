import Foundation
import Testing
@testable import GymCore

/// Plan 39: the limits an outside workout or a day must fit (server/migrations/0013_health_activities.sql CHECKs the
/// same numbers). The import skips one that doesn't fit; nothing is clamped.
@Suite struct ActivityLimitsTests {
    private let start = ISO8601DateFormatter().date(from: "2026-09-25T07:00:00Z")!

    private func walk(kind: String = "walking", minutes: Double = 45, durationS: Double? = nil, kcal: Double? = 180,
                      totalKcal: Double? = 231, distanceM: Double? = 3_400, avgHr: Int? = 102, maxHr: Int? = 121,
                      avgPowerW: Int? = 96, avgCadenceRpm: Int? = 62, source: String = "Apple Watch") -> HealthActivity {
        HealthActivity(id: UUID(), kind: kind, startedAt: start, endedAt: start.addingTimeInterval(minutes * 60),
                       durationS: durationS ?? minutes * 60, kcal: kcal, totalKcal: totalKcal, distanceM: distanceM,
                       avgHr: avgHr, maxHr: maxHr, avgPowerW: avgPowerW, avgCadenceRpm: avgCadenceRpm,
                       sourceName: source, fromWatch: true)
    }

    @Test func aWalkFits() {
        #expect(DomainLimits.healthActivityViolation(walk()) == nil)
        #expect(DomainLimits.healthActivityViolation(walk(kcal: nil, totalKcal: nil, distanceM: nil, avgHr: nil,
                                                          maxHr: nil, avgPowerW: nil, avgCadenceRpm: nil)) == nil)
        #expect(DomainLimits.healthActivityViolation(walk(kcal: 20_000, totalKcal: 20_000, avgPowerW: 2_500,
                                                          avgCadenceRpm: 250)) == nil)
        #expect(DomainLimits.healthActivityViolation(walk(kcal: 0, totalKcal: 0, avgPowerW: 0, avgCadenceRpm: 0))
            == nil)
    }

    @Test func anOutsideWorkoutOutsideALimitIsRefused() {
        #expect(DomainLimits.healthActivityViolation(walk(kind: "")) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(source: String(repeating: "s", count: 101))) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(minutes: -1)) != nil, "ends before it starts")
        #expect(DomainLimits.healthActivityViolation(walk(minutes: 1_500, durationS: 90_000)) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(durationS: .nan)) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(kcal: 20_001)) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(distanceM: 1_000_001)) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(avgHr: 19)) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(maxHr: 251)) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(totalKcal: 20_001)) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(avgPowerW: 2_501)) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(avgPowerW: -1)) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(avgCadenceRpm: 251)) != nil)
    }

    @Test func theNewLimitsAreTheSpecsNumbers() {
        #expect(DomainLimits.activityPowerW == 0...2_500)
        #expect(DomainLimits.activityCadenceRpm == 0...250)
        #expect(DomainLimits.activityKcal == 0...20_000, "total kcal shares the kcal limit")
    }

    @Test func aDayFitsUnlessAValueIsOutOfRange() {
        let day = ActivityDay(day: "2026-09-26", steps: 4_210, moveKcal: 210, exerciseMin: 18, standH: nil)
        #expect(DomainLimits.activityDayViolation(day) == nil)
        let tooMany = ActivityDay(day: "2026-09-26", steps: 200_001, moveKcal: 210, exerciseMin: 18, standH: 6)
        #expect(DomainLimits.activityDayViolation(tooMany) != nil)
        let longDay = ActivityDay(day: "2026-09-26", steps: 0, moveKcal: 0, exerciseMin: 1_441, standH: nil)
        #expect(DomainLimits.activityDayViolation(longDay) != nil)
        let standing = ActivityDay(day: "2026-09-26", steps: 0, moveKcal: 0, exerciseMin: 0, standH: 25)
        #expect(DomainLimits.activityDayViolation(standing) != nil)
        let burning = ActivityDay(day: "2026-09-26", steps: 0, moveKcal: 20_001, exerciseMin: 0, standH: nil)
        #expect(DomainLimits.activityDayViolation(burning) != nil)
    }

    @Test func theCapsAreTheSpecsNumbers() {
        #expect(DomainLimits.healthActivitiesMax == 20_000)
        #expect(DomainLimits.activityDaysMax == 5_000)
    }
}
