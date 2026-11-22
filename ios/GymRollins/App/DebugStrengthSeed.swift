#if DEBUG
import Foundation
import GymCore
import GymData
import SwiftData

/// DEBUG/UI-test only (`-seedStrength`): a sample lifter, a 30-year-old man at 76 kg, with a squat and deadlift from
/// before the ankle sprain and this month's bench (150 lb × 10 → e1RM 90.7 kg), for the strength-level screens.
/// Keeps the sample seed's ankle note, so squat and deadlift show as paused. Adds nothing already present.
@MainActor
enum DebugStrengthSeed {
    private static func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }

    static func apply(context: ModelContext, now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) throws {
        let profiles = ProfileRepository(context: context, now: { now })
        let profile = try profiles.load()
        if profile.sex == nil || profile.birthYear == nil {
            try profiles.setStrengthProfile(sex: .male, birthYear: calendar.component(.year, from: now) - 30)
        }
        let body = BodyRepository(context: context, now: { now })
        if try body.latest() == nil {
            try body.add(BodyweightEntry(date: now.addingTimeInterval(-86_400), weightKg: 76, timeOfDay: "morning"))
        }
        let workouts = WorkoutRepository(context: context, now: { now })
        let seeded = Set(try workouts.recent(limit: 500).flatMap { $0.entries.map(\.exerciseId) })
        for (id, daysAgo, weight, reps) in [("0043", 60.0, 245.0, 5), ("0032", 58.0, 315.0, 5),
                                            ("0025", 10.0, 150.0, 10)] where !seeded.contains(id) {
            let start = now.addingTimeInterval(-daysAgo * 86_400)
            try workouts.save(Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "Strength",
                                      entries: [WorkoutEntry(exerciseId: id, sets: (0..<3).map { _ in
                                          WorkoutSet(weightKg: lb(weight), reps: reps, done: true, completedAt: start)
                                      })]))
        }
    }
}
#endif
