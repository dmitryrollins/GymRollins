import Foundation
import GymCore
import SwiftData

/// Owner's split for DEBUG builds and UI tests. Idempotent: does nothing if any routine exists.
@MainActor
public enum OwnerSeed {
    static func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }

    static func ex(_ id: String, _ sets: Int, _ reps: Int, _ repsMin: Int? = nil, lb w: Double?, sg: String? = nil) -> RoutineExercise {
        RoutineExercise(exerciseId: id, sets: sets, reps: reps, repsMin: repsMin, weightKg: w.map(lb), incKg: lb(5),
                        supersetGroup: sg)
    }

    /// The Push/Pull/Upper/Legs split's routines and weekday schedule, no profile or history attached.
    private static func splitRoutines() -> (push: Routine, pull: Routine, upper: Routine, legs: Routine) {
        let push = Routine(name: "Push + Arms", exercises: [
            ex("0025", 3, 10, 8, lb: 140),                 // barbell bench press
            ex("0314", 3, 10, 8, lb: 45),                  // dumbbell incline bench press
            ex("0319", 3, 12, 10, lb: 27.5, sg: "A"),      // dumbbell incline fly
            ex("0155", 3, 12, 10, lb: 25, sg: "A"),        // cable cross-over variation
            ex("0194", 3, 10, 8, lb: 40),                  // cable overhead triceps extension (rope)
            ex("0313", 3, 10, 8, lb: 22.5),                // dumbbell hammer curl
            ex("0070", 3, 10, 8, lb: 55),                  // barbell preacher curl
        ])
        let pull = Routine(name: "Pull + Shoulders + Triceps", exercises: [
            ex("0198", 3, 10, 8, lb: 120),                 // cable pulldown
            ex("0861", 3, 12, 10, lb: 120),                // cable seated row
            ex("0541", 3, 12, 10, lb: 44),                 // kettlebell one arm row
            ex("0203", 3, 12, 10, lb: 30),                 // cable rear delt row (rope) — face pull
            ex("0603", 3, 10, 8, lb: 65),                  // lever shoulder press
            ex("0194", 3, 10, 8, lb: 35),                  // rope overhead extension
            ex("0201", 3, 10, 8, lb: 50),                  // cable pushdown
        ])
        let upper = Routine(name: "Upper weak points", exercises: [
            ex("0405", 3, 10, 8, lb: 30),                  // dumbbell seated shoulder press
            ex("0334", 4, 12, 10, lb: 10),                 // dumbbell lateral raise
            ex("0215", 3, 12, 10, lb: 10),                 // cable seated rear lateral raise
            ex("0030", 3, 8, 6, lb: 95),                   // barbell close-grip bench press
            ex("0251", 3, 10, 6, lb: nil),                 // chest dip
            ex("0070", 3, 10, 8, lb: 55),                  // barbell preacher curl
        ])
        let legs = Routine(name: "Legs", paused: true, exercises: [
            ex("0085", 3, 8, 8, lb: 135),                  // barbell romanian deadlift
            ex("0043", 4, 6, 6, lb: 135),                  // barbell full squat
            ex("0739", 3, 10, 8, lb: 170),                 // sled 45° leg press
            ex("0586", 3, 12, 10, lb: 100),                // lever lying leg curl
            ex("0585", 3, 10, 8, lb: 110),                 // lever leg extension
            ex("0594", 4, 15, 12, lb: 195),                // lever seated calf raise
        ])
        return (push, pull, upper, legs)
    }

    public static func apply(to context: ModelContext, now: Date) throws {
        let routines = RoutineRepository(context: context, now: { now })
        guard try routines.all().isEmpty else { return }
        let split = splitRoutines()
        for r in [split.push, split.pull, split.upper, split.legs] { try routines.upsert(r) }
        for (weekday, routine) in [(1, split.push), (3, split.pull), (5, split.upper), (6, split.push)] {
            try routines.setSchedule(weekday: weekday, routineId: routine.id)
        }
        try ProfileRepository(context: context, now: { now }).save(Profile(
            unit: .lb, heightCm: 185, goalWeightKg: 85,
            goalDate: Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 31)), // a calendar day
            trainingDays: 4, limits: "Knee: no leg loading until ~26 Oct 2026"))
    }

    /// Onboarding's "use the Push/Pull/Upper/Legs template" option: the same routines and schedule as `apply`,
    /// but no profile overwrite (the user's own answers from Profile Setup stay) and no workout history.
    /// Idempotent: does nothing if any routine exists.
    public static func applyTemplate(to context: ModelContext, now: Date) throws {
        let routines = RoutineRepository(context: context, now: { now })
        guard try routines.all().isEmpty else { return }
        let split = splitRoutines()
        for r in [split.push, split.pull, split.upper, split.legs] { try routines.upsert(r) }
        for (weekday, routine) in [(1, split.push), (3, split.pull), (5, split.upper), (6, split.push)] {
            try routines.setSchedule(weekday: weekday, routineId: routine.id)
        }
    }

    /// Two real bench sessions (12 Sep: 3×6 @130 lb; 19 Sep: 3×10 @130 lb) so Today suggests 135 lb and PRs can fire.
    public static func applyHistory(to context: ModelContext, now: Date) throws {
        let workouts = WorkoutRepository(context: context, now: { now })
        guard try workouts.recent(limit: 1).isEmpty else { return }
        let bench = { (day: String, reps: Int) -> Workout in
            let start = ISO8601DateFormatter().date(from: "\(day)T18:00:00Z")!
            return Workout(startedAt: start, endedAt: start.addingTimeInterval(3_500), name: "Push + Biceps", entries: [
                WorkoutEntry(exerciseId: "0025", sets: (0..<3).map { _ in
                    WorkoutSet(weightKg: lb(130), reps: reps, done: true, completedAt: start) }),
            ])
        }
        try workouts.save(bench("2026-09-12", 6))
        try workouts.save(bench("2026-09-19", 10))
    }

    /// 5 weekly weigh-ins, 81.0 → 81.8 kg, the last one on `now`, for screenshots/QA of the Body
    /// tab's chart and trend with real data.
    public static func applyBodyweight(to context: ModelContext, now: Date) throws {
        let body = BodyRepository(context: context, now: { now })
        guard try body.entries(since: nil).isEmpty else { return }
        for week in 0..<5 {
            let date = now.addingTimeInterval(Double(week - 4) * 7 * 86_400)
            let weightKg = 81.0 + 0.2 * Double(week)
            try body.add(BodyweightEntry(date: date, weightKg: weightKg, timeOfDay: "morning"))
        }
    }

    /// One extra "Core" workout with a 3×30s plank entry, 2 days before `now` (after
    /// `applyHistory`'s two bench sessions, so it's the most recent workout). The exercise id
    /// doesn't match the bundled library, so `SetFieldFormat.mode` falls back to `.time` from the
    /// sets' shape -- exercising the detail screen's timed-set display/edit without touching
    /// `applyHistory`'s fixed 2-workout/58:20 shape that other tests depend on.
    public static func applyPlank(to context: ModelContext, now: Date) throws {
        let workouts = WorkoutRepository(context: context, now: { now })
        let seeded = (try? workouts.recent(limit: 500)) ?? []
        guard !seeded.contains(where: { workout in workout.entries.contains { $0.exerciseId == "seed.plank" } }) else { return }
        let start = now.addingTimeInterval(-2 * 86_400)
        let plankSet = { WorkoutSet(weightKg: 0, reps: 1, sec: 30, done: true, completedAt: start) }
        let workout = Workout(startedAt: start, endedAt: start.addingTimeInterval(600), name: "Core", entries: [
            WorkoutEntry(exerciseId: "seed.plank", sets: [plankSet(), plankSet(), plankSet()]),
        ])
        try workouts.save(workout)
    }

    /// Exercises the synthetic history rotates through (all in the owner's plan).
    static let largeHistoryExerciseIds = ["0025", "0314", "0319", "0155", "0194", "0313", "0070", "0198"]

    /// `count` synthetic workouts (default 60), one per day going back from `now`, for testing Log's pagination
    /// (50-at-a-time) and, with 150, scroll/query performance. Each has 4 exercises × 3 working sets (rotating
    /// through `largeHistoryExerciseIds`, bench always first), like a real imported session.
    public static func applyLargeHistory(to context: ModelContext, now: Date, count: Int = 60) throws {
        let workouts = WorkoutRepository(context: context, now: { now })
        guard try workouts.recent(limit: 1).isEmpty else { return }
        let ids = largeHistoryExerciseIds
        for day in 0..<count {
            let start = now.addingTimeInterval(Double(-(day + 1)) * 86_400)
            let exerciseIds = [ids[0]] + (0..<3).map { ids[1 + (day + $0) % (ids.count - 1)] }
            let entries = exerciseIds.enumerated().map { index, id in
                WorkoutEntry(exerciseId: id, sets: (0..<3).map { set in
                    WorkoutSet(weightKg: lb(Double(100 - index * 15 + (day % 5) * 5)), reps: 8 + set % 2, done: true,
                               completedAt: start.addingTimeInterval(Double(index * 3 + set) * 150))
                })
            }
            let workout = Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600),
                                  name: "Synthetic \(day)", entries: entries)
            try workouts.save(workout)
        }
    }
}
