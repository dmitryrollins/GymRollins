import Foundation
import os

/// Keeps the running rest of the in-progress workout across app launches. Only the workout and its clock are in the
/// SwiftData store; the rest used to live in memory, which lost it when iOS terminated the app mid-rest, while the
/// rest notification and the Live Activity (which outlive the process) still showed it.
struct ActiveRestStore {
    private struct Stored: Codable {
        let workoutId: UUID
        let rest: RestTimer
    }

    static let key = "activeRest"
    let defaults: UserDefaults
    private static let log = Logger(subsystem: "com.rollins.gymrollins", category: "rest")

    /// The saved rest, only when it belongs to `workoutId`.
    func load(workoutId: UUID) -> RestTimer? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            return stored.workoutId == workoutId ? stored.rest : nil
        } catch {
            Self.log.error("Saved rest unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Saves `rest` for `workoutId`, or clears it when nil.
    func save(_ rest: RestTimer?, workoutId: UUID) {
        guard let rest else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(Stored(workoutId: workoutId, rest: rest)), forKey: Self.key)
        } catch {
            Self.log.error("Saving rest failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The rest duration chosen for one in-progress workout when it differs from the profile default (Today's "Rest
/// today"), so a relaunch restores the workout with it.
struct ActiveRestDurationStore {
    private struct Stored: Codable {
        let workoutId: UUID
        let seconds: Int
    }

    static let key = "activeRestSeconds"
    let defaults: UserDefaults

    func load(workoutId: UUID) -> Int? {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.workoutId == workoutId
        else { return nil }
        return stored.seconds
    }

    /// Saves `seconds` for `workoutId`, or clears the stored value when nil.
    func save(_ seconds: Int?, workoutId: UUID) {
        guard let seconds, let data = try? JSONEncoder().encode(Stored(workoutId: workoutId, seconds: seconds)) else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}
