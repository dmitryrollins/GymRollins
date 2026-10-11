import Foundation
import Testing
@testable import GymRollins

@Suite struct RestTimerTests {
    @Test func remainingAndAdjust() {
        let t0 = Date(timeIntervalSince1970: 100)
        let timer = RestTimer(startedAt: t0, duration: 120)
        #expect(timer.remaining(at: t0.addingTimeInterval(36)) == 84)
        #expect(timer.remaining(at: t0.addingTimeInterval(500)) == 0)
        #expect(timer.isFinished(at: t0.addingTimeInterval(120)))
        #expect(timer.adjusted(by: 15).remaining(at: t0) == 135)
        #expect(timer.adjusted(by: -200).remaining(at: t0) == 0)
        #expect(timer.endsAt == t0.addingTimeInterval(120))
    }

    @Test func formatting() {
        #expect(RestTimer(startedAt: .now, duration: 84).label(at: .now) == "1:24")
    }

    /// The notification interval is computed against "now" at scheduling time (after the
    /// permission prompt), and nothing is scheduled once the deadline has (nearly) passed.
    @Test func notificationIntervalRecomputedAndSkippedWhenPassed() {
        let end = Date(timeIntervalSince1970: 1_000)
        #expect(RestNotificationSchedule.interval(endsAt: end, now: Date(timeIntervalSince1970: 880)) == 120)
        #expect(RestNotificationSchedule.interval(endsAt: end, now: Date(timeIntervalSince1970: 970)) == 30)
        #expect(RestNotificationSchedule.interval(endsAt: end, now: Date(timeIntervalSince1970: 999.5)) == nil)
        #expect(RestNotificationSchedule.interval(endsAt: end, now: Date(timeIntervalSince1970: 1_030)) == nil)
    }

    @Test func soundPreferenceGatesNotificationSoundAndHaptic() {
        #expect(RestNotificationSchedule.content(soundEnabled: true).sound != nil)
        #expect(RestNotificationSchedule.content(soundEnabled: false).sound == nil)
        #expect(RestFeedback.onRestCompleted(soundEnabled: true) == .success)
        #expect(RestFeedback.onRestCompleted(soundEnabled: false) == nil)
    }

    @Test func preferencesDefaultOnAndReadSavedValues() throws {
        let defaults = try #require(UserDefaults(suiteName: "RestTimerTests.\(UUID())"))
        #expect(RestPreferences.restEnabled(defaults))
        #expect(RestPreferences.soundEnabled(defaults))
        defaults.set(false, forKey: RestPreferences.enabledKey)
        defaults.set(false, forKey: RestPreferences.soundKey)
        #expect(!RestPreferences.restEnabled(defaults))
        #expect(!RestPreferences.soundEnabled(defaults))
    }
}
