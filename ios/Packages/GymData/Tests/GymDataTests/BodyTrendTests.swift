import Foundation
import Testing
@testable import GymData

@Suite struct BodyTrendTests {
    let day: TimeInterval = 86_400
    let t0 = ISO8601DateFormatter().date(from: "2026-09-01T07:00:00Z")!

    @Test func emptyHasNoTrend() {
        let trend = BodyTrend(entries: [], goalKg: 85, goalDate: nil, now: t0)
        #expect(trend.currentKg == nil)
        #expect(trend.progress == 0)
        #expect(trend.weeklyChangeKg == nil)
    }

    @Test func progressAndWeeklySlope() throws {
        // +0.2 kg per week over 4 weeks, starting 81.0
        let entries = (0...4).map { BodyweightEntry(date: t0.addingTimeInterval(Double($0) * 7 * day), weightKg: 81 + 0.2 * Double($0)) }
        let trend = BodyTrend(entries: entries, goalKg: 85, goalDate: nil, now: t0.addingTimeInterval(28 * day))
        #expect(trend.startKg == 81)
        #expect(trend.currentKg == 81.8)
        #expect(abs(try #require(trend.weeklyChangeKg) - 0.2) < 0.001)
        #expect(abs(trend.progress - 0.2) < 0.001)          // 0.8 of 4 kg
        let projected = try #require(trend.projectedGoalDate)  // 3.2 kg at 0.2/week = 16 weeks
        #expect(abs(projected.timeIntervalSince(t0.addingTimeInterval(28 * day)) - 16 * 7 * day) < day)
    }

    @Test func losingWeightHasNoProjection() {
        let entries = [BodyweightEntry(date: t0, weightKg: 82), BodyweightEntry(date: t0.addingTimeInterval(14 * day), weightKg: 81.5)]
        let trend = BodyTrend(entries: entries, goalKg: 85, goalDate: nil, now: t0.addingTimeInterval(14 * day))
        #expect(trend.projectedGoalDate == nil)
        #expect(trend.progress == 0) // below start -> clamped
    }

    @Test func requiredWeeklyRateToHitGoalDate() throws {
        let goalDate = t0.addingTimeInterval(20 * 7 * day)
        let trend = BodyTrend(entries: [BodyweightEntry(date: t0, weightKg: 81)], goalKg: 85, goalDate: goalDate, now: t0)
        #expect(abs(try #require(trend.requiredWeeklyKg) - 0.2) < 0.001)
    }
}
