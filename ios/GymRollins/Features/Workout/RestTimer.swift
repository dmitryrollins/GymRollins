import Foundation
import GymCore
import UserNotifications
import os

struct RestTimer: Codable, Equatable, Sendable {
    let startedAt: Date
    let duration: TimeInterval

    var endsAt: Date { startedAt.addingTimeInterval(duration) }

    func remaining(at now: Date) -> TimeInterval { max(0, endsAt.timeIntervalSince(now)) }
    func isFinished(at now: Date) -> Bool { remaining(at: now) <= 0 }
    func adjusted(by seconds: TimeInterval) -> RestTimer {
        RestTimer(startedAt: startedAt, duration: max(0, duration + seconds))
    }
    func label(at now: Date) -> String { DurationFormatter.clock(remaining(at: now).rounded(.up)) }
}

@MainActor
protocol RestNotifier {
    func schedule(endsAt: Date)
    func cancel()
}

struct NoopRestNotifier: RestNotifier {
    func schedule(endsAt: Date) {}
    func cancel() {}
}

/// Saved rest preferences (written by RestSettingsSheet's `@AppStorage` toggles), read wherever
/// they take effect: session creation/restoration, notification delivery and the haptic.
enum RestPreferences {
    static let enabledKey = "restTimerEnabled"
    static let soundKey = "restSound"

    static func restEnabled(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }
    static func soundEnabled(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: soundKey) as? Bool ?? true }
}

/// Pure pieces of the rest-over notification, separated for testing.
enum RestNotificationSchedule {
    /// Seconds from `now` until the rest ends, or nil when it has (nearly) passed already.
    static func interval(endsAt: Date, now: Date) -> TimeInterval? {
        let seconds = endsAt.timeIntervalSince(now)
        return seconds > 1 ? seconds : nil
    }

    static func content(soundEnabled: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Rest over"
        content.body = "Time for your next set."
        content.sound = soundEnabled ? .default : nil
        return content
    }
}

/// Local notification when rest ends (app in background). Asks for permission on first use; the
/// delay is computed only after that (possibly slow) prompt, against the app's clock.
@MainActor
struct UserNotificationRestNotifier: RestNotifier {
    let now: () -> Date
    let soundEnabled: () -> Bool
    private let id = "rest-timer"
    private static let log = Logger(subsystem: "com.rollins.gymrollins", category: "rest")

    func schedule(endsAt: Date) {
        guard RestNotificationSchedule.interval(endsAt: endsAt, now: now()) != nil else { return }
        let center = UNUserNotificationCenter.current()
        let id = self.id
        Task {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                center.removePendingNotificationRequests(withIdentifiers: [id])
                guard let seconds = RestNotificationSchedule.interval(endsAt: endsAt, now: now()) else { return }
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
                let content = RestNotificationSchedule.content(soundEnabled: soundEnabled())
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            } catch {
                Self.log.error("Rest notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
