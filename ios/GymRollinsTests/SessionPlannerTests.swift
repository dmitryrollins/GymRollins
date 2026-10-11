import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@Suite struct SessionPlannerTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private func inLb(_ kg: Double) -> Double { (UnitConverter.fromKg(kg, to: .lb) * 10).rounded() / 10 }
    private let library = ExerciseLibrary(exercises: [
        Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
        Exercise(id: "0313", name: "dumbbell hammer curl", bodyPart: "upper arms", equipment: "dumbbell", target: "biceps"),
    ])

    @Test func buildsEntriesWithWarmupsAndSuggestions() {
        let routine = Routine(name: "Push + Arms", exercises: [
            RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, repsMin: 8, weightKg: lb(130), incKg: lb(5)),
            RoutineExercise(exerciseId: "0313", sets: 3, reps: 10, repsMin: 8, weightKg: lb(22.5), incKg: lb(2.5)),
        ])
        let history = ["0025": [SessionResult(date: .now, weightKg: lb(130), reps: [10, 10, 10])]]
        let start = Date(timeIntervalSince1970: 1_000)
        let w = SessionPlanner.start(routine: routine, profile: Profile(), library: library, now: start,
                                     history: { history[$0] ?? [] })
        #expect(w.name == "Push + Arms")
        #expect(w.routineId == routine.id)
        #expect(w.startedAt == start)
        let bench = w.entries[0]
        #expect(bench.sets.filter(\.warmup).map { inLb($0.weightKg) } == [45, 100])   // 75% of 135 -> 100 lb
        #expect(bench.sets.filter { !$0.warmup }.map { inLb($0.weightKg) } == [135, 135, 135])
        #expect(bench.sets.filter { !$0.warmup }.map(\.reps) == [8, 8, 8])
        let curl = w.entries[1]
        #expect(curl.sets.allSatisfy { !$0.warmup })          // no warm-ups for dumbbells
        #expect(curl.sets.allSatisfy { $0.multiplier == 2 })  // dumbbell pair
        #expect(curl.sets.count == 3)
    }

    @Test func bodyweightExerciseHasZeroWeight() {
        let lib = ExerciseLibrary(exercises: [
            Exercise(id: "0251", name: "chest dip", bodyPart: "chest", equipment: "body weight", target: "pectorals")])
        let routine = Routine(name: "Upper", exercises: [RoutineExercise(exerciseId: "0251", sets: 3, reps: 10)])
        let w = SessionPlanner.start(routine: routine, profile: Profile(), library: lib, now: .now, history: { _ in [] })
        #expect(w.entries[0].sets.map(\.weightKg) == [0, 0, 0])
        #expect(w.entries[0].sets.map(\.reps) == [10, 10, 10])
    }

    @Test func emptyWorkoutForQuickStart() {
        let w = SessionPlanner.empty(now: Date(timeIntervalSince1970: 5))
        #expect(w.entries.isEmpty)
        #expect(w.name == "Workout")
    }

    /// Dumbbells and kettlebells are logged per arm (each arm holds its own bell, or works in turn), so they count
    /// twice; one bell held in both hands counts once.
    @Test func kettlebellsCountPerArmButOneBellInBothHandsCountsOnce() {
        let lib = { (name: String, equipment: String) in
            Exercise(id: name, name: name, bodyPart: "back", equipment: equipment, target: "lats")
        }
        let perArm = [("kettlebell one arm row", "kettlebell"), ("kettlebell seated press", "kettlebell"),
                      ("kettlebell one arm floor press", "kettlebell"), ("dumbbell hammer curl", "dumbbell")]
        for (name, equipment) in perArm {
            #expect(SessionPlanner.multiplier(for: lib(name, equipment)) == 2, "\(name)")
        }
        let oneBell = [("kettlebell seated two arm military press", "kettlebell"), ("kettlebell goblet squat", "kettlebell"),
                       ("kettlebell figure 8", "kettlebell"), ("kettlebell halo", "kettlebell"),
                       ("dumbbell pullover", "dumbbell"), ("dumbbell waiter biceps curl", "dumbbell")]
        for (name, equipment) in oneBell {
            #expect(SessionPlanner.multiplier(for: lib(name, equipment)) == 1, "\(name)")
        }
        #expect(SessionPlanner.isPerArm(lib("kettlebell one arm row", "kettlebell")))
        #expect(!SessionPlanner.isPerArm(lib("barbell bench press", "barbell")))
    }

    @Test func multiplierHonorsCustomBilateralAndLibraryDumbbells() {
        let customSingle = Exercise(id: "c1", name: "one-arm db row", bodyPart: "back", equipment: "dumbbell",
                                    target: "lats", isCustom: true, bilateral: false)
        let customPair = Exercise(id: "c2", name: "db press", bodyPart: "chest", equipment: "dumbbell",
                                  target: "pectorals", isCustom: true, bilateral: true)
        let customCable = Exercise(id: "c3", name: "cable thing", bodyPart: "chest", equipment: "cable",
                                   target: "pectorals", isCustom: true, bilateral: true)
        #expect(SessionPlanner.multiplier(for: customSingle) == 1)
        #expect(SessionPlanner.multiplier(for: customPair) == 2)
        #expect(SessionPlanner.multiplier(for: customCable) == 2)
        #expect(SessionPlanner.multiplier(for: library.exercise("0313")) == 2)
        #expect(SessionPlanner.multiplier(for: library.exercise("0025")) == 1)
        #expect(SessionPlanner.multiplier(for: nil) == 1)

        let lib = ExerciseLibrary(exercises: [customSingle])
        let routine = Routine(name: "Back", exercises: [RoutineExercise(exerciseId: "c1", sets: 2, reps: 10)])
        let w = SessionPlanner.start(routine: routine, profile: Profile(), library: lib, now: .now, history: { _ in [] })
        #expect(w.entries[0].sets.map(\.multiplier) == [1, 1])
    }

    @Test func adHocEntryUsesModeAwareDefaults() {
        let plank = Exercise(id: "p1", name: "plank", bodyPart: "waist", equipment: "body weight", target: "abs",
                             mode: .time)
        let timed = SessionPlanner.adHocEntry(exerciseId: "p1", exercise: plank, profile: Profile(), history: [],
                                                 autoWarmups: true)
        #expect(timed.sets.count == 3)
        #expect(timed.sets.allSatisfy { $0.sec == 30 })
        let run = Exercise(id: "r1", name: "run", bodyPart: "cardio", equipment: "body weight", target: "heart")
        let cardio = SessionPlanner.adHocEntry(exerciseId: "r1", exercise: run, profile: Profile(), history: [],
                                                 autoWarmups: true)
        #expect(cardio.sets.count == 1)
        #expect(cardio.sets[0].sec == 1_200)
        let unknown = SessionPlanner.adHocEntry(exerciseId: "zz", exercise: nil, profile: Profile(), history: [],
                                                 autoWarmups: true)
        #expect(unknown.sets.count == 3)
        #expect(unknown.sets.allSatisfy { $0.reps == 8 && $0.sec == nil })
    }

    /// Codex P2: the second session of a timed exercise (in a routine whose policy is load-based, or added ad hoc)
    /// still targets a duration, progressed by time.
    @Test func secondTimedSessionKeepsADurationTarget() {
        let plank = Exercise(id: "p1", name: "plank", bodyPart: "waist", equipment: "body weight", target: "abs",
                             mode: .time)
        let lib = ExerciseLibrary(exercises: [plank])
        let history = [SessionResult(date: .now, weightKg: 0, reps: [1, 1, 1], secs: [30, 30, 30])]
        let routine = Routine(name: "Core", policy: .double, exercises: [
            RoutineExercise(exerciseId: "p1", sets: 3, reps: 1, sec: 30, mode: .time),
        ])
        let w = SessionPlanner.start(routine: routine, profile: Profile(), library: lib, now: .now,
                                     history: { _ in history })
        #expect(w.entries[0].sets.map(\.sec) == [35, 35, 35])
        let adHoc = SessionPlanner.adHocEntry(exerciseId: "p1", exercise: plank, profile: Profile(), history: history,
                                              autoWarmups: true)
        #expect(adHoc.sets.map(\.sec) == [35, 35, 35])
    }

    /// Adding a barbell lift mid-workout follows the Warm-up sets preference like session start does.
    @Test func adHocEntryHonorsWarmupPreference() {
        let bench = library.exercise("0025")
        let history = [SessionResult(date: .now, weightKg: lb(135), reps: [10, 10, 10])]
        let on = SessionPlanner.adHocEntry(exerciseId: "0025", exercise: bench, profile: Profile(), history: history,
                                           autoWarmups: true)
        #expect(on.sets.contains { $0.warmup })
        let off = SessionPlanner.adHocEntry(exerciseId: "0025", exercise: bench, profile: Profile(), history: history,
                                            autoWarmups: false)
        #expect(!off.sets.contains { $0.warmup })
        #expect(off.sets.count == on.sets.filter { !$0.warmup }.count)
    }

    @Test func swapWeightFollowsHistoryOrKeeps() {
        let curl = library.exercise("0313")
        #expect(SessionPlanner.swapWeightKg(exercise: curl, profile: Profile(), history: []) == nil)
        let history = [SessionResult(date: .now, weightKg: lb(25), reps: [10, 10, 10])]
        let suggested = SessionPlanner.swapWeightKg(exercise: curl, profile: Profile(), history: history)
        #expect(suggested.map(inLb) == 27.5)
    }
}
