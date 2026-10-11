import Foundation
import GymCore
import GymData
import os

/// The bundled raw-competitor table (`Resources/strength-standards.json`), decoded once.
enum BundledStrengthStandards {
    private static let log = Logger(subsystem: "com.rollins.gymrollins", category: "strength")

    static let shared: StrengthStandards? = {
        guard let url = Bundle.main.url(forResource: "strength-standards", withExtension: "json") else {
            log.error("strength-standards.json missing from the bundle")
            return nil
        }
        do { return try StrengthStandards.decode(Data(contentsOf: url)) } catch {
            log.error("Strength standards failed to load: \(String(describing: error), privacy: .public)")
            return nil
        }
    }()
}

extension AppEnvironment {
    /// Levels for squat/bench/deadlift as of now; nil if the table can't load or the store fails (logged).
    func strengthReport() -> StrengthReport? {
        guard let standards = BundledStrengthStandards.shared else { return nil }
        do {
            let since = now().addingTimeInterval(-Double(StrengthReport.windowDays) * 86_400)
            return StrengthReport.make(standards: standards, workouts: try workouts.finished(since: since),
                                       sex: profile.sex, birthYear: profile.birthYear,
                                       bodyweightKg: try body.latest()?.weightKg, limits: profile.limits,
                                       now: now(), calendar: .current)
        } catch {
            Self.log.error("Strength report failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Saves (or clears) the strength-level inputs and schedules a sync.
    func setStrengthProfile(sex: ProfileSex?, birthYear: Int?) throws {
        try profiles.setStrengthProfile(sex: sex, birthYear: birthYear)
        reloadProfile()
        planChanged()
    }
}
