import Foundation
import Testing
@testable import GymCore

/// The rules against the real library and requirements, at the owner's real home setup: a flat bench and kettlebells
/// of 20 and 24 kg.
@Suite struct GymRealDataTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("GymRollins/Resources")

    private static func load(_ name: String) throws -> Data {
        try Data(contentsOf: resources.appendingPathComponent(name))
    }

    private let library: [Exercise]
    private let matcher: InventoryMatcher
    private let startDay = 20_400

    init() throws {
        library = try JSONDecoder().decode([Exercise].self, from: Self.load("exercises.json"))
        let requirements = try ExerciseRequirements.decode(Self.load("equipment-requirements.json"))
        matcher = InventoryMatcher(requirements: requirements,
                                   kinds: try EquipmentKind.decodeList(Self.load("equipment-kinds.json")),
                                   inventory: GymFixtures.home)
    }

    /// Builds and "completes" the same request `days` days in a row.
    private func consecutive(_ muscles: [BuildMuscle], _ length: BuildLength, days: Int = 4) -> [BuiltWorkout] {
        (0..<days).reduce(into: (history: [Workout](), built: [BuiltWorkout]())) { state, offset in
            let built = WorkoutBuilder(matcher: matcher, exercises: library, history: state.history)
                .build(BuildRequest(muscles: muscles, length: length, date: GymFixtures.date(day: startDay + offset)))
            state.built.append(built)
            state.history.append(GymFixtures.workout(day: startDay + offset, built.items.map(\.exercise.exerciseId)))
        }.built
    }

    @Test(arguments: [[BuildMuscle.chest], [.back], [.shoulders], [.arms], [.legs], [.core], [.chest, .back],
                      [.arms, .shoulders], [.legs, .core]])
    func criterion3AtHome(muscles: [BuildMuscle]) {
        let builder = WorkoutBuilder(matcher: matcher, exercises: library, history: [])
        let available = muscles.reduce(0) { total, muscle in
            let pool = builder.pool(for: muscle, day: startDay, asOf: GymFixtures.date(day: startDay))
            return total + pool.equipment.count + pool.bodyweight.count
        }
        for length in BuildLength.allCases where available >= 2 * length.slots(muscleCount: muscles.count) {
            let workouts = consecutive(muscles, length).map { $0.items.map(\.exercise.exerciseId) }
            for (previous, next) in zip(workouts, workouts.dropFirst()) {
                let changed = Set(next).subtracting(previous).count
                #expect(changed * 2 >= next.count, "\(muscles) \(length): \(previous) → \(next)")
            }
        }
    }

    @Test func aRepeatIsOnlyUsedWhenNoFreshExerciseIsLeft() {
        for built in consecutive([.arms], .medium, days: 6) {
            let repeats = built.items.filter { $0.repeatOf != nil }
            #expect(repeats.isEmpty, "\(repeats.map(\.exercise.exerciseId))")
        }
    }

    @Test func aDifferentDayGivesADifferentWorkout() {
        let workouts = (0..<7).map { offset in
            WorkoutBuilder(matcher: matcher, exercises: library, history: [])
                .build(BuildRequest(muscles: [.arms], length: .medium, date: GymFixtures.date(day: startDay + offset)))
                .items.map(\.exercise.exerciseId)
        }
        #expect(Set(workouts).count >= 5, "\(workouts)")
    }

    /// Pins the output so a tie-break that varies per process (such as `hashValue`) fails here.
    @Test func theSameRequestGivesTheSameWorkoutOnEveryRun() {
        let shuffled = WorkoutBuilder(matcher: matcher, exercises: library.reversed(), history: [])
        let built = shuffled.build(BuildRequest(muscles: [.arms], length: .medium,
                                                date: GymFixtures.date(day: startDay)))
        #expect(built.items.map(\.exercise.exerciseId) == ["0518", "0490", "0525", "0137"])
    }

    @Test func noPickIsAStretchOrAdvancedSkill() {
        let skipped = /stretch|yoga|pose|toe touch|circles|pelvic tilt|sphinx|upward facing|planche|handstand|boxing/
        let names = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0.name) })
        for muscle in BuildMuscle.allCases {
            let builder = WorkoutBuilder(matcher: matcher, exercises: library, history: [])
            let pool = builder.pool(for: muscle, day: startDay, asOf: GymFixtures.date(day: startDay))
            for candidate in pool.equipment + pool.bodyweight {
                let name = names[candidate.exercise.id, default: ""]
                #expect(name.firstMatch(of: skipped) == nil, "\(name)")
            }
        }
    }

    @Test func aThinGymSaysSoEvenWhenFillsCoverEverySlot() {
        let built = WorkoutBuilder(matcher: matcher, exercises: library, history: [])
            .build(BuildRequest(muscles: [.back], length: .long, date: GymFixtures.date(day: startDay)))
        #expect(built.items.count == 6)
        #expect(built.items.contains { $0.isBodyweightFill })
        #expect(built.thin.first?.muscle == .back)
    }
}
