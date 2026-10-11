#if DEBUG
import Foundation
import GymCore
import GymData
import SwiftData

/// DEBUG/UI-test only (`-seedInsights`): six weeks of the owner's Mon/Wed/Fri/Sat split ending with this week's
/// Monday push, Wednesday pull and Friday upper session (3 of the 4-day goal; the week before met it), so the
/// recovery map shows fatigued shoulders/triceps and fresh back muscles, the weekly bars have data, the streak
/// is 5 weeks, and finishing today's workout completes the week. Does nothing if any workout exists.
@MainActor
enum DebugInsightsSeed {
    private static func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }

    private static let push: [(String, Int, Double)] = [("0025", 3, 140), ("0314", 3, 45), ("0194", 3, 40),
                                                        ("0313", 3, 22.5)]
    private static let pull: [(String, Int, Double)] = [("0198", 3, 120), ("0861", 3, 120), ("0203", 3, 30),
                                                        ("0201", 3, 50)]
    private static let upper: [(String, Int, Double)] = [("0405", 3, 30), ("0334", 4, 10), ("0030", 3, 95),
                                                         ("0070", 3, 55)]

    static func apply(context: ModelContext, now: Date, calendar: Calendar = TrainingWeek.calendar()) throws {
        let repo = WorkoutRepository(context: context, now: { now })
        guard try repo.recent(limit: 1).isEmpty else { return }
        let thisWeek = TrainingWeek.interval(containing: now, calendar: calendar).start
        for weeksBack in (1...5).reversed() {
            let monday = calendar.date(byAdding: .weekOfYear, value: -weeksBack, to: thisWeek) ?? thisWeek
            for (offset, plan, name) in [(0, push, "Push + Arms"), (2, pull, "Pull + Shoulders + Triceps"),
                                         (4, upper, "Upper weak points"), (5, push, "Push + Arms")] {
                try repo.save(workout(name, plan, day: monday, offset: offset, calendar: calendar))
            }
        }
        for (offset, plan, name) in [(0, push, "Push + Arms"), (2, pull, "Pull + Shoulders + Triceps"),
                                     (4, upper, "Upper weak points")] {
            let w = workout(name, plan, day: thisWeek, offset: offset, calendar: calendar)
            if w.startedAt < now { try repo.save(w) }
        }
    }

    /// 18:00 local on `day + offset`, one hour long, every set done.
    private static func workout(_ name: String, _ plan: [(String, Int, Double)], day: Date, offset: Int,
                                calendar: Calendar) -> Workout {
        let date = calendar.date(byAdding: .day, value: offset, to: day) ?? day
        let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: date) ?? date
        let entries = plan.map { id, sets, weight in
            WorkoutEntry(exerciseId: id, sets: (0..<sets).map { _ in
                WorkoutSet(weightKg: lb(weight), reps: 10, done: true, completedAt: start)
            })
        }
        return Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: name, entries: entries)
    }
}
#endif
