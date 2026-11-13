import Foundation
import Testing
@testable import GymCore

/// Rows as they are in the bundled library (`Resources/exercises.json`).
@Suite struct ExerciseRestTests {
    private func exercise(_ name: String, _ equipment: String, _ secondary: [String],
                          mode: ExerciseMode = .reps) -> Exercise {
        Exercise(id: name, name: name, bodyPart: "chest", equipment: equipment, target: "pectorals",
                 secondary: secondary, mode: mode)
    }

    private var bench: Exercise { exercise("barbell bench press", "barbell", ["triceps", "shoulders"]) }
    private var fly: Exercise { exercise("dumbbell incline fly", "dumbbell", ["shoulders"]) }
    private var inclineDumbbell: Exercise { exercise("dumbbell incline bench press", "dumbbell", ["shoulders", "triceps"]) }

    @Test func bigBarbellLifts() {
        #expect(ExerciseRest.kind(of: bench) == .bigLift)
        #expect(ExerciseRest.kind(of: exercise("barbell full squat", "barbell",
                                               ["quadriceps", "hamstrings", "calves", "core"])) == .bigLift)
        #expect(ExerciseRest.kind(of: exercise("barbell bent over row", "barbell", ["biceps", "forearms"])) == .bigLift)
    }

    @Test func singleMuscleMovesByNameEvenWithNoisySecondaryMuscles() {
        #expect(ExerciseRest.kind(of: exercise("barbell preacher curl", "barbell", ["forearms"])) == .isolation)
        #expect(ExerciseRest.kind(of: fly) == .isolation)
        #expect(ExerciseRest.kind(of: exercise("cable cross-over variation", "cable", ["deltoids", "triceps"]))
                == .isolation)
        #expect(ExerciseRest.kind(of: exercise("cable overhead triceps extension (rope attachment)", "cable",
                                               ["shoulders"])) == .isolation)
        #expect(ExerciseRest.kind(of: exercise("dumbbell hammer curl", "dumbbell", ["forearms"])) == .isolation)
    }

    @Test func noSecondaryMusclesIsIsolationAndTheNameIsMatchedIgnoringCase() {
        #expect(ExerciseRest.kind(of: exercise("Machine Chest Press", "leverage machine", [])) == .isolation)
        #expect(ExerciseRest.kind(of: exercise("Barbell Wrist CURL", "barbell", ["forearms", "biceps"])) == .isolation)
        #expect(ExerciseRest.kind(of: exercise("barbell front raise", "barbell", ["shoulders", "chest"])) == .isolation,
                "the name beats barbell + two secondary muscles")
    }

    @Test func everythingElse() {
        #expect(ExerciseRest.kind(of: inclineDumbbell) == .other, "not barbell-loaded")
        #expect(ExerciseRest.kind(of: exercise("barbell upright row", "barbell", ["biceps"])) == .other,
                "a barbell lift with one secondary muscle")
        #expect(ExerciseRest.kind(of: exercise("barbell squat hold", "barbell", ["glutes", "core"], mode: .time))
                == .other, "only reps exercises get a suggestion")
    }

    @Test func suggestionRaisesBigLiftsAndCapsIsolation() {
        #expect(ExerciseRest.suggested(for: bench, defaultSec: 120) == 180)
        #expect(ExerciseRest.suggested(for: bench, defaultSec: 240) == 240)
        #expect(ExerciseRest.suggested(for: fly, defaultSec: 120) == 90)
        #expect(ExerciseRest.suggested(for: fly, defaultSec: 240) == 90)
        #expect(ExerciseRest.suggested(for: fly, defaultSec: 60) == 60)
        #expect(ExerciseRest.suggested(for: inclineDumbbell, defaultSec: 120) == 120)
        #expect(ExerciseRest.suggested(for: nil, defaultSec: 120) == 120, "an unknown exercise rests the default")
    }

    @Test func theOwnersRestWins() {
        #expect(ExerciseRest.working(custom: 300, exercise: fly, defaultSec: 120) == 300)
        #expect(ExerciseRest.working(custom: nil, exercise: fly, defaultSec: 120) == 90)
        #expect(ExerciseRest.working(custom: nil, exercise: nil, defaultSec: 150) == 150)
        #expect(ExerciseRest.working(custom: 45, exercise: nil, defaultSec: 150) == 45)
    }

    @Test func choosingTheSuggestionKeepsNoOwnRest() {
        #expect(ExerciseRest.custom(choosing: 180, exercise: bench, defaultSec: 120) == nil)
        #expect(ExerciseRest.custom(choosing: 210, exercise: bench, defaultSec: 120) == 210)
        #expect(ExerciseRest.custom(choosing: 120, exercise: nil, defaultSec: 120) == nil)
        #expect(ExerciseRest.custom(choosing: 120, exercise: fly, defaultSec: 120) == 120)
    }
}
