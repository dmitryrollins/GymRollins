import GymCore
import GymData
import Testing
@testable import GymRollins

@Suite struct RoutineDefaultsTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }

    @Test func repsModeBarbellDefaults() {
        let ex = Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell",
                          target: "pectorals")
        let item = RoutineDefaults.item(for: ex, profile: Profile())
        #expect(item.exerciseId == "0025")
        #expect(item.mode == .reps)
        #expect(item.sets == 3)
        #expect(item.reps == 10)
        #expect(item.repsMin == 8)
        #expect(item.incKg == lb(5))
    }

    @Test func repsModeNonBarbellDefaults() {
        let ex = Exercise(id: "0032", name: "dumbbell romanian deadlift", bodyPart: "upper legs",
                          equipment: "dumbbell", target: "hamstrings")
        let item = RoutineDefaults.item(for: ex, profile: Profile())
        #expect(item.mode == .reps)
        #expect(item.sets == 3)
        #expect(item.reps == 10)
        #expect(item.repsMin == 8)
        #expect(item.incKg == lb(2.5))
    }

    @Test func timeModeDefaults() {
        let ex = Exercise(id: "0900", name: "plank", bodyPart: "waist", equipment: "body weight", target: "abs",
                          mode: .time)
        let item = RoutineDefaults.item(for: ex, profile: Profile())
        #expect(item.mode == .time)
        #expect(item.sets == 3)
        #expect(item.reps == 1)
        #expect(item.sec == 30)
    }

    @Test func cardioModeDefaults() {
        let ex = Exercise(id: "1200", name: "treadmill run", bodyPart: "cardio", equipment: "stationary bike",
                          target: "cardiovascular system")
        let item = RoutineDefaults.item(for: ex, profile: Profile())
        #expect(item.mode == .cardio)
        #expect(item.sets == 1)
        #expect(item.reps == 1)
        #expect(item.sec == 1200)
    }
}
