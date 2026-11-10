import Foundation
import Testing
@testable import GymCore

@Suite struct SharedWorkoutTests {
    private func item(_ id: String, sets: Int = 3, _ target: SharedWorkout.Target = .reps(min: nil, max: 10),
                      superset: Int? = nil) -> SharedWorkout.Item {
        SharedWorkout.Item(exerciseId: id, sets: sets, target: target, superset: superset)
    }

    private func decode(_ text: String) -> SharedWorkout.Decoded { SharedWorkout.decode(text) { _ in true } }

    private func set(_ reps: Int = 8, weight: Double = 63.5, sec: Int? = nil, minutes: Double? = nil,
                     warmup: Bool = false) -> WorkoutSet {
        WorkoutSet(weightKg: weight, reps: reps, sec: sec, minutes: minutes, warmup: warmup)
    }

    // MARK: The text

    @Test func writesTheSpecsFormat() {
        let workout = SharedWorkout(items: [
            item("0001", .reps(min: 8, max: 10)),
            item("1512", superset: 1),
            item("0201", .reps(min: nil, max: 12), superset: 1),
            item("0300", sets: 1, .seconds(600)),
        ])
        #expect(workout.linkText == "1.0001_3_8-10.1512_3_10_g1.0201_3_12_g1.0300_1_s600")
    }

    @Test func roundTrips() {
        let workout = SharedWorkout(items: [
            item("0001", .reps(min: 8, max: 10)),
            item("ABCDEFGH", sets: 10, .reps(min: nil, max: 100), superset: 2),
            item("7", sets: 1, .seconds(5)),
            item("0300", sets: 1, .seconds(3600)),
        ])
        #expect(decode(workout.linkText) == .valid(workout, droppedUnknown: 0))
    }

    @Test(arguments: [
        "", "1", "1.", "1..0001_3_10", "1.0001_3_10.", ".0001_3_10", "abc.0001_3_10", "0.0001_3_10", "01.0001_3_10",
        "1.0001_3", "1.0001", "1.0001_3_10_g1_x", "1.0001_0_10", "1.0001_11_10", "1.0001_03_10", "1.0001_+3_10",
        "1.0001_3_0", "1.0001_3_101", "1.0001_3_10-8", "1.0001_3_8-10-12", "1.0001_3_-10", "1.0001_3_8-",
        "1.0001_3_s4", "1.0001_3_s3601", "1.0001_3_s", "1.0001_3_10_g0", "1.0001_3_10_g21", "1.0001_3_10_x1",
        "1.0001_3_10_g", "1.custom-1_3_10", "1.ABCDEFGHI_3_10", "1._3_10", "1.\u{00FF}_3_10", "1.0001_3_\u{0661}\u{0660}",
        "1.0001_3_10 ", "1.0001%5F3%5F10",
    ])
    func refusesBrokenText(text: String) {
        #expect(decode(text) == .damaged)
    }

    @Test(arguments: ["1.0001_1_1", "1.0001_10_100", "1.0001_3_s5", "1.0001_3_s3600", "1.0001_3_8-8", "1.0001_3_10_g20",
                      "1.ABCDEFGH_3_10"])
    func acceptsTheLimits(text: String) {
        guard case let .valid(workout, dropped) = decode(text) else {
            Issue.record("\(text) should be valid")
            return
        }
        #expect(workout.items.count == 1)
        #expect(dropped == 0)
    }

    @Test func refusesTooLong() {
        #expect(decode("1." + String(repeating: "0", count: SharedWorkout.maxLinkLength)) == .damaged)
    }

    @Test func refusesMoreThanARoutinesExercises() {
        let fields = { (count: Int) in (0..<count).map { "\(1_000 + $0)_3_10" }.joined(separator: ".") }
        guard case let .valid(workout, _) = decode("1." + fields(DomainLimits.routineExercisesMax)) else {
            Issue.record("20 exercises should be valid")
            return
        }
        #expect(workout.items.count == DomainLimits.routineExercisesMax)
        #expect(decode("1." + fields(DomainLimits.routineExercisesMax + 1)) == .damaged)
    }

    @Test(arguments: ["2", "2.anything", "999.0001_3_10"])
    func newerVersionsAreTooNew(text: String) {
        #expect(decode(text) == .tooNew)
    }

    @Test func dropsAndCountsUnknownExercises() {
        let decoded = SharedWorkout.decode("1.0001_3_10.9999_3_10.0002_3_10") { $0 != "9999" }
        #expect(decoded == .valid(SharedWorkout(items: [item("0001"), item("0002")]), droppedUnknown: 1))
    }

    @Test func allUnknownIsDamaged() {
        #expect(SharedWorkout.decode("1.0001_3_10") { _ in false } == .damaged)
    }

    @Test func randomTextNeverCrashesAndAnythingValidRoundTrips() {
        var generator = SeededGenerator(seed: 23)
        let alphabet = Array("0123456789_-.gsABC \u{00FF}%#")
        for _ in 0..<5_000 {
            let length = Int.random(in: 0...40, using: &generator)
            let text = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
            if case let .valid(workout, _) = decode(text) {
                #expect(decode(workout.linkText) == .valid(workout, droppedUnknown: 0))
            }
        }
    }

    /// The random strings above almost never parse, so this starts from valid links and changes one character.
    @Test func aValidLinkWithOneCharacterChangedStillRoundTripsWhenItIsValid() {
        var generator = SeededGenerator(seed: 7)
        let base = "1.0001_3_8-10.1512_3_10_g1.0201_3_12_g1.0300_1_s600"
        let alphabet = Array("0123456789_-.gsx")
        var stillValid = 0
        for _ in 0..<2_000 {
            var characters = Array(base)
            characters[Int.random(in: 0..<characters.count, using: &generator)] = alphabet.randomElement(using: &generator)!
            guard case let .valid(workout, _) = decode(String(characters)) else { continue }
            stillValid += 1
            #expect(decode(workout.linkText) == .valid(workout, droppedUnknown: 0))
        }
        #expect(stillValid > 50, "only \(stillValid) mutations stayed valid, so the round trip hardly ran")
    }

    @Test func aRepeatedExerciseIsDamaged() {
        #expect(decode("1.0001_3_10.0002_3_10.0001_2_8") == .damaged)
    }

    // MARK: Sending

    @Test func aRunningWorkoutWithAnExerciseTwiceSendsTheFirst() {
        let draft = SharedWorkout.make(from: [
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0001", sets: 3, reps: 10)),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0002", sets: 3, reps: 10)),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0001", sets: 5, reps: 5)),
        ])
        #expect(draft.workout?.items.map(\.exerciseId) == ["0001", "0002"])
        #expect(draft.workout?.items.first?.sets == 3)
        let text = draft.workout?.linkText ?? ""
        #expect(decode(text) != .damaged)
    }

    @Test func aRunningWorkoutSendsThePlansNumberNotWhatWasJustLogged() throws {
        let done = WorkoutSet(weightKg: 60, reps: 12, done: true)
        let next = WorkoutSet(weightKg: 60, reps: 8)
        let source = try #require(SharedWorkout.Source(exerciseId: "0001", group: nil, sets: [done, next, next]))
        #expect(source.target == .reps(min: nil, max: 8))
        let allDone = try #require(SharedWorkout.Source(exerciseId: "0001", group: nil, sets: [done, done]))
        #expect(allDone.target == .reps(min: nil, max: 12))
    }

    @Test func clampsValuesSoASenderCanAlwaysShare() {
        let sources = [
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0001", sets: 15, reps: 500)),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0002", sets: 0, reps: 0)),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0003", sets: 3, reps: 5, repsMin: 8)),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0004", sets: 3, reps: 1, sec: 1, mode: .time)),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0005", sets: 3, reps: 1, sec: 9_000, mode: .cardio)),
        ]
        let workout = SharedWorkout.make(from: sources).workout
        #expect(workout?.items == [
            item("0001", sets: 10, .reps(min: nil, max: 100)),
            item("0002", sets: 1, .reps(min: nil, max: 1)),
            item("0003", .reps(min: nil, max: 5)),
            item("0004", .seconds(5)),
            item("0005", .seconds(3600)),
        ])
    }

    @Test func keepsTheFirstTwentyAndCountsTheRest() {
        let sources = (0..<23).map { SharedWorkout.Source(item: RoutineExercise(exerciseId: "\($0)", sets: 3, reps: 10)) }
        let draft = SharedWorkout.make(from: sources)
        #expect(draft.workout?.items.map(\.exerciseId) == (0..<20).map { "\($0)" })
        #expect(draft.cutOffCount == 3)
    }

    @Test func leavesCustomExercisesOutAndNamesThem() {
        let draft = SharedWorkout.make(from: [
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "custom-abc", sets: 3, reps: 10)),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0001", sets: 3, reps: 10)),
        ])
        #expect(draft.workout?.items.map(\.exerciseId) == ["0001"])
        #expect(draft.leftOutIds == ["custom-abc"])
    }

    @Test func onlyCustomExercisesLeavesNothingToSend() {
        let draft = SharedWorkout.make(from: [
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "custom-abc", sets: 3, reps: 10)),
        ])
        #expect(draft.workout == nil)
        #expect(draft.leftOutIds == ["custom-abc"])
    }

    @Test func renumbersSupersetsAndNeverSendsTheLabel() {
        let draft = SharedWorkout.make(from: [
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0001", sets: 3, reps: 10, supersetGroup: "call-me")),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0002", sets: 3, reps: 10)),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0003", sets: 3, reps: 10, supersetGroup: "z")),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0004", sets: 3, reps: 10, supersetGroup: "call-me")),
        ])
        #expect(draft.workout?.items.map(\.superset) == [1, nil, 2, 1])
        #expect(draft.workout?.linkText.contains("call-me") == false)
    }

    @Test func noWeightOrWarmUpEverReachesTheText() throws {
        let entry = WorkoutEntry(exerciseId: "0025", sets: [
            set(5, weight: 20, warmup: true), set(8, weight: 63.5), set(8, weight: 63.5), set(8, weight: 63.5),
        ])
        let source = try #require(SharedWorkout.Source(entry: entry))
        let text = try #require(SharedWorkout.make(from: [source]).workout?.linkText)
        #expect(text == "1.0025_3_8")
    }

    @Test func routineItemsCarryTheirWeightsNowhere() {
        let source = SharedWorkout.Source(item: RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, repsMin: 8,
                                                                 weightKg: 63.5, weightSetAt: .now))
        let items = SharedWorkout.make(from: [source]).workout?.routineItems { _ in .reps } ?? []
        #expect(items.map(\.weightKg) == [nil])
        #expect(items.map(\.weightSetAt) == [nil])
        #expect(items.map(\.repsMin) == [8])
        #expect(items.map(\.reps) == [10])
    }

    @Test func editedSetsUseTheWorkingCountAndTheFirstSet() throws {
        let source = try #require(SharedWorkout.Source(exerciseId: "0001", group: "A", sets: [
            set(12, warmup: true), set(10), set(6),
        ]))
        #expect(source == SharedWorkout.Source(exerciseId: "0001", sets: 2, target: .reps(min: nil, max: 10), group: "A"))
    }

    @Test func onlyWarmUpsMeansNoSource() {
        #expect(SharedWorkout.Source(exerciseId: "0001", group: nil, sets: [set(warmup: true)]) == nil)
    }

    @Test func timedAndCardioSetsBecomeSeconds() throws {
        let timed = try #require(SharedWorkout.Source(exerciseId: "0001", group: nil, sets: [set(sec: 45)]))
        #expect(timed.target == .seconds(45))
        let cardio = try #require(SharedWorkout.Source(exerciseId: "0002", group: nil, sets: [set(minutes: 10)]))
        #expect(cardio.target == .seconds(600))
    }

    @Test func secondsBecomeCardioOnlyWhenTheLibrarySaysSo() {
        let workout = SharedWorkout(items: [item("0001", .seconds(60)), item("0002", .seconds(600)), item("0003")])
        let items = workout.routineItems { $0 == "0002" ? .cardio : .reps }
        #expect(items.map(\.mode) == [.time, .cardio, .reps])
        #expect(items.map(\.sec) == [60, 600, nil])
    }

    /// The logging screen shows a seconds box only when no set has reps (`SetFieldFormat.dataMode`).
    @Test func aTimedSetHasNoRepsAndCardioKeepsOne() {
        let workout = SharedWorkout(items: [item("0001", .seconds(60)), item("0002", .seconds(600))])
        let items = workout.routineItems { $0 == "0002" ? .cardio : .reps }
        #expect(items.map(\.reps) == [0, 1])
    }

    @Test func aRepsTargetOnACardioExerciseBecomesCardio() throws {
        let workout = SharedWorkout(items: [item("0002", sets: 3, .reps(min: 8, max: 10))])
        let only = try #require(workout.routineItems { _ in .cardio }.first)
        let defaults = RoutineExercise.defaults(exerciseId: "0002", mode: .cardio, barbell: false)
        #expect(only.mode == .cardio && only.sec == defaults.sec && only.reps == 1 && only.repsMin == nil)
    }

    @Test func supersetsStayTogetherOnThePhone() {
        let workout = SharedWorkout(items: [item("0001", superset: 1), item("0002", superset: 1), item("0003", superset: 2)])
        let groups = workout.routineItems { _ in .reps }.map(\.supersetGroup)
        #expect(groups[0] != nil)
        #expect(groups[0] == groups[1])
        #expect(groups[1] != groups[2])
    }
}

/// A small repeatable generator, so a failure in the random test can be reproduced.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
