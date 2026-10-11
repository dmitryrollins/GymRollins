import Testing
@testable import GymCore

@Suite struct ExerciseMatcherTests {
    private let library = [
        Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
        Exercise(id: "0313", name: "dumbbell hammer curl", bodyPart: "upper arms", equipment: "dumbbell", target: "biceps"),
        Exercise(id: "0150", name: "cable pulldown", bodyPart: "back", equipment: "cable", target: "lats",
                 aliases: ["Lat Pulldown"]),
        Exercise(id: "0600", name: "dumbbell incline bench press", bodyPart: "chest", equipment: "dumbbell",
                 target: "pectorals"),
        Exercise(id: "0700", name: "barbell incline bench press", bodyPart: "chest", equipment: "barbell",
                 target: "pectorals"),
    ]

    @Test func exactIgnoresCaseAndPunctuation() {
        #expect(ExerciseMatcher(library: library).match("Barbell Bench-Press") ==
                ExerciseMatch(exerciseId: "0025", kind: .exact, score: 1))
    }

    @Test func aliasMatch() {
        #expect(ExerciseMatcher(library: library).match("Lat Pulldown")?.kind == .alias)
        #expect(ExerciseMatcher(library: library).match("Lat Pulldown")?.exerciseId == "0150")
    }

    @Test func fuzzyMatchHandlesPlurals() throws {
        let m = try #require(ExerciseMatcher(library: library).match("Hammer Curls"))
        #expect(m.exerciseId == "0313")
        #expect(m.kind == .fuzzy)
        #expect(m.score >= 0.6)
    }

    @Test func fuzzyPrefersBestScore() throws {
        let m = try #require(ExerciseMatcher(library: library).match("Dumbbell Incline Bench Press"))
        #expect(m.exerciseId == "0600")
        #expect(m.kind == .exact)
    }

    @Test func noMatchBelowThreshold() {
        #expect(ExerciseMatcher(library: library).match("Glute Ham Raise") == nil)
    }

    @Test func normalize() {
        #expect(ExerciseMatcher.normalize("  Cable  Rope-Overhead (Triceps) ") == "cable rope overhead triceps")
    }

    @Test func ambiguousFuzzyTieReturnsNil() {
        // "barbell incline bench press" and "dumbbell incline bench press" tie at the same jaccard
        // score against "Incline Bench Press" - ambiguous, so the app should ask the user instead
        // of silently guessing.
        #expect(ExerciseMatcher(library: library).match("Incline Bench Press") == nil)
    }
}
