import Testing
@testable import GymCore

@Suite struct ExercisePreferenceTests {
    private let prefs: [String: ExercisePreference] = ["b": .more, "c": .less, "d": .never, "e": .normal]

    @Test func rawValuesMatchTheDatabase() {
        #expect(ExercisePreference.allCases.map(\.rawValue) == ["more", "normal", "less", "never"])
        #expect(ExercisePreference(rawValue: "never") == .never)
        #expect(ExercisePreference(storedValue: "bogus") == .normal)
        #expect(ExercisePreference(storedValue: nil) == .normal)
    }

    @Test func suggestionsPutMoreFirstLessLastAndDropNever() {
        let ranked = ExerciseRanking.suggestions(["a", "b", "c", "d", "e"], preferences: prefs, id: { $0 })
        #expect(ranked == ["b", "a", "e", "c"])
    }

    @Test func suggestionsKeepTheIncomingOrderWithinAGroup() {
        let ranked = ExerciseRanking.suggestions(["z", "c", "y", "b", "x", "b2"],
                                                 preferences: ["b": .more, "b2": .more, "c": .less], id: { $0 })
        #expect(ranked == ["b", "b2", "z", "y", "x", "c"])
    }

    @Test func searchResultsKeepNeverExercisesLast() {
        let ranked = ExerciseRanking.searchResults(["d", "a", "c", "b"], preferences: prefs, id: { $0 })
        #expect(ranked == ["b", "a", "c", "d"])
    }

    @Test func noPreferencesChangesNothing() {
        #expect(ExerciseRanking.suggestions(["c", "a", "b"], preferences: [:], id: { $0 }) == ["c", "a", "b"])
        #expect(ExerciseRanking.searchResults(["c", "a", "b"], preferences: [:], id: { $0 }) == ["c", "a", "b"])
    }

    @Test func toggledSetsOrClearsAChoice() {
        #expect(ExercisePreference.normal.toggled(.more) == .more)
        #expect(ExercisePreference.more.toggled(.more) == .normal)
        #expect(ExercisePreference.less.toggled(.more) == .more)
        #expect(ExercisePreference.more.toggled(.less) == .less)
        #expect(ExercisePreference.never.toggled(.less) == .less)
    }
}
