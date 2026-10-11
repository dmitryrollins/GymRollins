import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Where the app recommends exercises (Replace/Swap candidates, the exercise picker's list) follows the owner's
/// "Recommend more often / less often / Don't recommend again" choices; an explicit search still finds everything.
@Suite struct ExerciseSuggestionsTests {
    private func ex(_ id: String, _ name: String, target: String = "pectorals", bodyPart: String = "chest") -> Exercise {
        Exercise(id: id, name: name, bodyPart: bodyPart, equipment: "barbell", target: target)
    }

    private var library: ExerciseLibrary {
        ExerciseLibrary(exercises: [
            ex("bench", "bench press"), ex("incline", "incline bench press"), ex("dips", "chest dip"),
            ex("fly", "cable fly"), ex("pec", "pec deck", target: "serratus"), ex("row", "barbell row", target: "lats",
                                                                                  bodyPart: "back"),
        ])
    }

    // MARK: Swap / Replace

    @Test func swapCandidatesKeepTheirOrderWithoutPreferences() {
        let ids = ExerciseSuggestions.swap(current: library.exercise("bench")!, library: library,
                                           loggedCounts: ["dips": 3, "fly": 1], preferences: [:], query: "")
            .map(\.id)
        #expect(ids == ["dips", "fly", "incline", "pec"], "same target by logged count then name, then same body part")
    }

    @Test func swapCandidatesPutMoreFirstLessLastAndHideNever() {
        let ids = ExerciseSuggestions.swap(current: library.exercise("bench")!, library: library,
                                           loggedCounts: ["dips": 3, "fly": 1],
                                           preferences: ["pec": .more, "dips": .less, "fly": .never], query: "")
            .map(\.id)
        #expect(ids == ["pec", "incline", "dips"])
    }

    @Test func searchingTheSwapListStillFindsNeverExercises() {
        let ids = ExerciseSuggestions.swap(current: library.exercise("bench")!, library: library, loggedCounts: [:],
                                           preferences: ["fly": .never], query: "fly").map(\.id)
        #expect(ids == ["fly"])
    }

    // MARK: Picker

    @Test func pickerSuggestionsHideNeverAndOrderByPreference() {
        let ids = ExerciseSuggestions.picker(library: library, query: "", excluded: ["row"],
                                             preferences: ["fly": .more, "bench": .never, "dips": .less],
                                             hidesNever: true).map(\.id)
        #expect(ids == ["fly", "incline", "pec", "dips"])
    }

    @Test func pickerSearchFindsNeverExercisesLast() {
        let ids = ExerciseSuggestions.picker(library: library, query: "bench", excluded: [],
                                             preferences: ["bench": .never, "incline": .more], hidesNever: true)
            .map(\.id)
        #expect(ids == ["incline", "bench"])
    }

    @Test func importMatchingNeverHidesAnything() {
        let ids = ExerciseSuggestions.picker(library: library, query: "", excluded: [],
                                             preferences: ["bench": .never], hidesNever: false).map(\.id)
        #expect(ids.contains("bench"))
        #expect(ids.last == "bench")
    }
}
