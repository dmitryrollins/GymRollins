import Foundation
import GymCore
import Testing
@testable import GymRollins

@Suite struct SetFieldFormatTests {
    private let id = UUID()

    /// Viewing a 22.25 lb set shows a rounded "22.3", but leaving that text unchanged must not
    /// rewrite the stored load (gram-based record keys depend on it).
    @Test func unchangedDisplayTextKeepsExactWeight() {
        let kg = UnitConverter.toKg(22.25, from: .lb)
        let set = WorkoutSet(id: id, weightKg: kg, reps: 10)
        let shown = SetFieldFormat.display(.weight(id), set: set, unit: .lb)
        #expect(shown == "22.3")
        let result = SetFieldFormat.applying(shown, to: .weight(id), set: set, unit: .lb)
        #expect(result == set)
        #expect(result?.weightKg == kg)
    }

    @Test func editedWeightAndRepsParse() {
        let set = WorkoutSet(id: id, weightKg: 60, reps: 8)
        #expect(SetFieldFormat.applying("140", to: .weight(id), set: set, unit: .lb)?.weightKg ==
                UnitConverter.toKg(140, from: .lb))
        #expect(SetFieldFormat.applying("62,5", to: .weight(id), set: set, unit: .kg)?.weightKg == 62.5)
        #expect(SetFieldFormat.applying("10", to: .reps(id), set: set, unit: .kg)?.reps == 10)
        #expect(SetFieldFormat.applying("", to: .reps(id), set: set, unit: .kg) == nil)
        #expect(SetFieldFormat.applying("abc", to: .weight(id), set: set, unit: .kg) == nil)
        #expect(SetFieldFormat.applying("-5", to: .weight(id), set: set, unit: .kg) == nil)
    }

    @Test func timedSetsEditSeconds() {
        let set = WorkoutSet(id: id, weightKg: 0, reps: 1, sec: 30)
        #expect(SetFieldFormat.display(.sec(id), set: set, unit: .lb) == "30")
        #expect(SetFieldFormat.applying("20", to: .sec(id), set: set, unit: .lb)?.sec == 20)
    }

    @Test func cardioEditsMinutesAndDistance() {
        let set = WorkoutSet(id: id, weightKg: 0, reps: 1, sec: 1_200)
        #expect(SetFieldFormat.display(.minutes(id), set: set, unit: .kg) == "20")
        #expect(SetFieldFormat.display(.distance(id), set: set, unit: .kg) == "")
        let minutes = SetFieldFormat.applying("25", to: .minutes(id), set: set, unit: .kg)
        #expect(minutes?.minutes == 25)
        #expect(minutes?.sec == 1_500)
        #expect(SetFieldFormat.applying("5", to: .distance(id), set: set, unit: .kg)?.distanceM == 5_000)
        let miles = SetFieldFormat.applying("2", to: .distance(id), set: set, unit: .lb)?.distanceM ?? 0
        #expect(abs(miles - 3_218.688) < 0.001)
        #expect(SetFieldFormat.applying("", to: .distance(id), set: set, unit: .kg)?.distanceM == nil)
    }

    @Test func modeFallsBackToSetShapeWithoutExercise() {
        #expect(SetFieldFormat.mode(exercise: nil, sets: [WorkoutSet(weightKg: 0, reps: 1, sec: 30)]) == .time)
        #expect(SetFieldFormat.mode(exercise: nil, sets: [WorkoutSet(weightKg: 50, reps: 5)]) == .reps)
        let plank = Exercise(id: "p", name: "plank", bodyPart: "waist", equipment: "body weight", target: "abs",
                             mode: .time)
        #expect(SetFieldFormat.mode(exercise: plank, sets: []) == .time)
    }

    /// Imported timed sets mapped to a rep-mode library entry (Fitbod Plank -> 2135, Single Leg Glute Bridge ->
    /// 3645) show and edit as duration, not "0 x 0 lb"; distance without reps shows as cardio.
    @Test func repModeExerciseWithDurationOnlySetsFollowsTheData() {
        let bridge = Exercise(id: "3645", name: "single leg bridge", bodyPart: "upper legs", equipment: "body weight",
                              target: "glutes")
        #expect(bridge.mode == .reps)
        let timed = [WorkoutSet(weightKg: 0, reps: 0, sec: 45), WorkoutSet(weightKg: 0, reps: 0, sec: 60)]
        #expect(SetFieldFormat.mode(exercise: bridge, sets: timed) == .time)
        let walked = [WorkoutSet(weightKg: 0, reps: 0, sec: 1_200, distanceM: 2_000)]
        #expect(SetFieldFormat.mode(exercise: bridge, sets: walked) == .cardio)
        // Any rep data keeps the library's rep mode; so does an entry with no sets yet.
        #expect(SetFieldFormat.mode(exercise: bridge, sets: timed + [WorkoutSet(weightKg: 0, reps: 12)]) == .reps)
        #expect(SetFieldFormat.mode(exercise: bridge, sets: [WorkoutSet(weightKg: 20, reps: 10)]) == .reps)
        #expect(SetFieldFormat.mode(exercise: bridge, sets: []) == .reps)
    }

    /// Time/cardio library entries keep their own mode (a treadmill run's sets carry seconds without distance).
    @Test func timeAndCardioLibraryModesAreKept() {
        let run = Exercise(id: "r", name: "run", bodyPart: "cardio", equipment: "body weight", target: "heart")
        #expect(run.mode == .cardio)
        #expect(SetFieldFormat.mode(exercise: run, sets: [WorkoutSet(weightKg: 0, reps: 0, sec: 1_200)]) == .cardio)
        let plank = Exercise(id: "p", name: "plank", bodyPart: "waist", equipment: "body weight", target: "abs",
                             mode: .time)
        #expect(SetFieldFormat.mode(exercise: plank, sets: [WorkoutSet(weightKg: 0, reps: 0, sec: 30,
                                                                         distanceM: 5)]) == .time)
    }

    @Test func fieldsPerMode() {
        #expect(SetFieldFormat.fields(for: .reps, setId: id) == [.reps(id), .weight(id)])
        #expect(SetFieldFormat.fields(for: .time, setId: id) == [.sec(id), .weight(id)])
        #expect(SetFieldFormat.fields(for: .cardio, setId: id) == [.minutes(id), .distance(id)])
    }

    /// Values outside the server's CHECK ranges (`DomainLimits`) are refused locally, like any invalid text.
    @Test func valuesOutsideDomainLimitsAreRejected() {
        let set = WorkoutSet(id: id, weightKg: 60, reps: 8)
        #expect(SetFieldFormat.applying("1001", to: .reps(id), set: set, unit: .kg) == nil)
        #expect(SetFieldFormat.applying("1000", to: .reps(id), set: set, unit: .kg)?.reps == 1_000)
        #expect(SetFieldFormat.applying("1001", to: .weight(id), set: set, unit: .kg) == nil)
        #expect(SetFieldFormat.applying("2300", to: .weight(id), set: set, unit: .lb) == nil) // ≈ 1043 kg
        #expect(SetFieldFormat.applying("86401", to: .sec(id), set: set, unit: .kg) == nil)
        #expect(SetFieldFormat.applying("1441", to: .minutes(id), set: set, unit: .kg) == nil)
        #expect(SetFieldFormat.applying("1001", to: .distance(id), set: set, unit: .kg) == nil) // km
        #expect(SetFieldFormat.applying("42.2", to: .distance(id), set: set, unit: .kg)?.distanceM.map { abs($0 - 42_200) < 0.001 } == true)
    }
}
