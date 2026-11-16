import Foundation
import Testing
@testable import GymCore

/// Plan 39's rules 6 and 7 beyond the shared fixture: which attached recording a GymRollins workout shows.
@Suite struct ActivityRulesTests {
    private let t0 = ISO8601DateFormatter().date(from: "2026-09-22T17:00:00Z")!

    private func activity(_ kind: String, from start: Double, minutes: Double, watch: Bool = false,
                          source: String = "Strava") -> HealthActivity {
        HealthActivity(id: UUID(), kind: kind, startedAt: t0.addingTimeInterval(start * 60),
                       endedAt: t0.addingTimeInterval((start + minutes) * 60), durationS: minutes * 60,
                       sourceName: source, fromWatch: watch)
    }

    @Test func theWatchsRecordingIsTheMeasuredOneOfASession() {
        let session = WorkoutSpan(id: UUID(), start: t0, end: t0.addingTimeInterval(3_600))
        let strava = activity("traditional_strength", from: 2, minutes: 56)
        let watch = activity("traditional_strength", from: 5, minutes: 50, watch: true, source: "Apple Watch")
        let resolved = ActivityRules.resolve([strava, watch], workouts: [session])
        #expect(resolved.shown.isEmpty)
        #expect(Set(resolved.attached(to: session.id).map(\.id)) == [strava.id, watch.id])
        #expect(resolved.measured(for: session.id) == watch)
        #expect(resolved.measured(for: UUID()) == nil)
    }

    @Test func withoutAWatchRecordingTheLongerIsMeasured() {
        let session = WorkoutSpan(id: UUID(), start: t0, end: t0.addingTimeInterval(3_600))
        let short = activity("functional_strength", from: 10, minutes: 40)
        let long = activity("functional_strength", from: 0, minutes: 58)
        #expect(ActivityRules.resolve([short, long], workouts: [session]).measured(for: session.id) == long)
    }

    @Test func aWorkoutThatSharesNoTimeAttachesNothing() {
        let instant = WorkoutSpan(id: UUID(), start: t0, end: t0)
        let walk = activity("walking", from: 0, minutes: 30)
        #expect(ActivityRules.resolve([walk], workouts: [instant]).shown == [walk])
        #expect(ResolvedActivities.none.counted.isEmpty)
        #expect(ResolvedActivities.none.attached.isEmpty)
    }
}
