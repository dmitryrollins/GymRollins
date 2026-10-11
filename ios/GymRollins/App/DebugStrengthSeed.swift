#if DEBUG
import Foundation
import GymCore
import GymData
import SwiftData

/// DEBUG/UI-test only (`-seedStrength`): the owner as a 35-year-old man at 81 kg with a squat and deadlift from
/// before the knee break and this month's bench (130 lb × 10 → e1RM 78.6 kg), for the strength-level screens.
/// Keeps the owner seed's knee note, so squat and deadlift show as paused. Adds nothing already present.
@MainActor
enum DebugStrengthSeed {
    private static func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }

    static func apply(context: ModelContext, now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) throws {
        let profiles = ProfileRepository(context: context, now: { now })
        let profile = try profiles.load()
        if profile.sex == nil || profile.birthYear == nil {
            try profiles.setStrengthProfile(sex: .male, birthYear: calendar.component(.year, from: now) - 35)
        }
        let body = BodyRepository(context: context, now: { now })
        if try body.latest() == nil {
            try body.add(BodyweightEntry(date: now.addingTimeInterval(-86_400), weightKg: 81, timeOfDay: "morning"))
        }
        let workouts = WorkoutRepository(context: context, now: { now })
        let seeded = Set(try workouts.recent(limit: 500).flatMap { $0.entries.map(\.exerciseId) })
        for (id, daysAgo, weight, reps) in [("0043", 60.0, 225.0, 5), ("0032", 58.0, 275.0, 5),
                                            ("0025", 10.0, 130.0, 10)] where !seeded.contains(id) {
            let start = now.addingTimeInterval(-daysAgo * 86_400)
            try workouts.save(Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "Strength",
                                      entries: [WorkoutEntry(exerciseId: id, sets: (0..<3).map { _ in
                                          WorkoutSet(weightKg: lb(weight), reps: reps, done: true, completedAt: start)
                                      })]))
        }
    }
}
#endif
