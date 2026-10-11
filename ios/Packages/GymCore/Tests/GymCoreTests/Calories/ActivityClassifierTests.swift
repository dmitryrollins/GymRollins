import Foundation
import Testing
@testable import GymCore

@Suite struct ActivityClassifierTests {
    private func cardio(_ name: String, _ equipment: String = "body weight") -> Exercise {
        Exercise(id: name, name: name, bodyPart: "cardio", equipment: equipment, target: "cardiovascular system")
    }

    /// The library's 29 cardio rows (bundled exercises.json) land on sensible Compendium activities.
    @Test(arguments: [
        ("run", "body weight", CardioKind.running), ("short stride run", "body weight", .running),
        ("jump rope", "rope", .jumpRope), ("walking on stepmill", "stepmill machine", .stairs),
        ("walk elliptical cross trainer", "elliptical machine", .elliptical),
        ("cycle cross trainer", "leverage machine", .elliptical),
        ("stationary bike walk", "leverage machine", .cycling), ("stationary bike run v. 3", "stationary bike", .cycling),
        ("walking on incline treadmill", "leverage machine", .inclineWalking),
        ("burpee", "body weight", .bodyweightIntervals), ("mountain climber", "body weight", .bodyweightIntervals),
        ("dumbbell burpee", "dumbbell", .bodyweightIntervals), ("treadmill", "leverage machine", .other),
        ("ski ergometer", "skierg machine", .skiErg),
        ("upper body ergometer", "upper body ergometer", .armErgometer), ("rowing machine", "leverage machine", .rowing),
    ])
    func cardioKinds(name: String, equipment: String, expected: CardioKind) {
        #expect(ActivityClassifier.activity(for: cardio(name, equipment), sets: []) == .cardio(expected))
    }

    @Test func strengthActivities() {
        let bench = Exercise(id: "b", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "p")
        let dl = Exercise(id: "d", name: "barbell romanian deadlift", bodyPart: "upper legs", equipment: "barbell",
                          target: "g")
        let pull = Exercise(id: "p", name: "pull-up", bodyPart: "back", equipment: "body weight", target: "lats")
        #expect(ActivityClassifier.activity(for: bench, sets: []) == .weights)
        #expect(ActivityClassifier.activity(for: dl, sets: []) == .squatDeadlift)
        #expect(ActivityClassifier.activity(for: pull, sets: []) == .calisthenics)
    }

    @Test func cardioModeOnCustomExerciseCountsAsCardio() {
        let custom = Exercise(id: "c", name: "assault bike", bodyPart: "upper legs", equipment: "leverage machine",
                              target: "quads", isCustom: true, mode: .cardio)
        #expect(ActivityClassifier.activity(for: custom, sets: []) == .cardio(.cycling))
    }

    @Test func healthKindsForCardio() {
        #expect(CardioKind.inclineWalking.healthActivity == .walking)
        #expect(CardioKind.stairs.healthActivity == .stairClimbing)
        #expect(CardioKind.other.healthActivity == .mixedCardio)
        #expect(CardioKind.skiErg.healthActivity == .mixedCardio)
    }
}

@Suite struct BodyWeightPickerTests {
    private let d0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func picksLatestOnOrBeforeElseEarliestAfter() {
        let samples = [BodyWeightSample(date: d0.addingTimeInterval(-86_400 * 7), weightKg: 80),
                       BodyWeightSample(date: d0.addingTimeInterval(-86_400), weightKg: 81),
                       BodyWeightSample(date: d0.addingTimeInterval(86_400), weightKg: 82)]
        #expect(BodyWeightPicker.weightKg(at: d0, samples: samples) == 81)
        #expect(BodyWeightPicker.weightKg(at: d0.addingTimeInterval(-86_400 * 30), samples: samples) == 80)
        #expect(BodyWeightPicker.weightKg(at: d0, samples: samples.reversed()) == 81)
        #expect(BodyWeightPicker.weightKg(at: d0, samples: []) == nil)
    }
}
