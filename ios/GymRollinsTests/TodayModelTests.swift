import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@Suite struct TodayModelTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private let library = ExerciseLibrary(exercises: [
        Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
        Exercise(id: "0032", name: "dumbbell romanian deadlift", bodyPart: "upper legs", equipment: "dumbbell",
                target: "hamstrings"),
    ])

    @Test func rowShowsPlanAndIncreaseBadge() {
        let routine = Routine(name: "Push + Arms", exercises: [
            RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, repsMin: 8, weightKg: lb(130), incKg: lb(5))])
        let history = ["0025": [SessionResult(date: .now, weightKg: lb(130), reps: [10, 10, 10])]]
        let model = TodayModel.make(routine: routine, profile: Profile(), library: library,
                                    history: { history[$0] ?? [] })
        #expect(model.title == "Push + Arms")
        #expect(model.rows.count == 1)
        #expect(model.rows[0].name == "Barbell Bench Press")
        #expect(model.rows[0].subtitle == "3 \u{00D7} 8\u{2013}10 \u{00B7} 135 lb (61.2 kg)")
        #expect(model.rows[0].badge == "+5 lb")
        #expect(model.summary == "1 exercise")
    }

    @Test func noBadgeOnFirstSession() {
        let routine = Routine(name: "Push", exercises: [
            RoutineExercise(exerciseId: "0025", sets: 3, reps: 8, weightKg: lb(140), incKg: lb(5))])
        let model = TodayModel.make(routine: routine, profile: Profile(), library: library, history: { _ in [] })
        #expect(model.rows[0].subtitle == "3 \u{00D7} 8 \u{00B7} 140 lb (63.5 kg)")
        #expect(model.rows[0].badge == nil)
    }

    @Test func dumbbellExerciseRoundsToDumbbellStep() {
        let routine = Routine(name: "Legs", exercises: [
            RoutineExercise(exerciseId: "0032", sets: 3, reps: 10, weightKg: lb(27.5), incKg: lb(2.5))])
        let model = TodayModel.make(routine: routine, profile: Profile(), library: library, history: { _ in [] })
        #expect(model.rows[0].subtitle == "3 \u{00D7} 10 \u{00B7} 27.5 lb (12.5 kg)")
    }

    @Test func barbellExerciseStillRoundsToBarbellStep() {
        let routine = Routine(name: "Push", exercises: [
            RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, weightKg: lb(27.5), incKg: lb(5))])
        let model = TodayModel.make(routine: routine, profile: Profile(), library: library, history: { _ in [] })
        #expect(model.rows[0].subtitle == "3 \u{00D7} 10 \u{00B7} 30 lb (13.6 kg)")
    }

    @Test func restDay() {
        let model = TodayModel.make(routine: nil, profile: Profile(), library: library, history: { _ in [] })
        #expect(model.rows.isEmpty)
        #expect(model.title == "Rest day")
    }
}
