import Foundation
import GymCore
import Testing
@testable import GymData

@Suite struct LibraryTests {
    static let sample = [
        Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
        Exercise(id: "0314", name: "dumbbell incline bench press", bodyPart: "chest", equipment: "dumbbell", target: "pectorals"),
        Exercise(id: "0198", name: "cable pulldown", bodyPart: "back", equipment: "cable", target: "lats"),
    ]

    @Test func searchByTextAndFilters() {
        let lib = ExerciseLibrary(exercises: Self.sample)
        #expect(lib.search(query: "bench").map(\.id) == ["0025", "0314"])
        #expect(lib.search(query: "BENCH", bodyPart: "chest", equipment: "dumbbell").map(\.id) == ["0314"])
        #expect(lib.search(query: "", bodyPart: "back").map(\.id) == ["0198"])
        #expect(lib.search(query: "pull down").map(\.id) == ["0198"])
    }

    @Test func lookupAndFacets() {
        let lib = ExerciseLibrary(exercises: Self.sample)
        #expect(lib.exercise("0198")?.name == "cable pulldown")
        #expect(lib.bodyParts == ["back", "chest"])
        #expect(lib.equipment == ["barbell", "cable", "dumbbell"])
    }

    @Test func mergingCustomExercises() {
        let custom = Exercise(id: "custom-1", name: "handle band squat to press", bodyPart: "upper legs",
                              equipment: "band", target: "quads", isCustom: true)
        let lib = ExerciseLibrary(exercises: Self.sample).merging(custom: [custom])
        #expect(lib.exercise("custom-1")?.isCustom == true)
        #expect(lib.search(query: "squat").map(\.id) == ["custom-1"])
    }

    // MARK: Names in other languages (wger)

    static let otherNames: [String: [String]] = [
        "0025": ["Bankdrücken LH", "Press de Banca", "Développé couché"],
        "0198": ["Latziehen", "Jalón al pecho"],
        "0314": ["Kurzhantel Schrägbank", "Latziehen"],
    ]

    @Test func searchMatchesOtherLanguageNames() {
        let lib = ExerciseLibrary(exercises: Self.sample, otherNames: Self.otherNames)
        #expect(lib.search(query: "Bankdrücken").map(\.id) == ["0025"], "all words must appear in one name")
        #expect(lib.search(query: "bankdrucken").map(\.id) == ["0025"], "diacritics are optional")
        #expect(lib.search(query: "developpe couche").map(\.id) == ["0025"])
        #expect(lib.search(query: "press de banca").map(\.id) == ["0025"])
        #expect(lib.search(query: "jalón", bodyPart: "back").map(\.id) == ["0198"])
        #expect(lib.search(query: "jalón", bodyPart: "chest").isEmpty, "filters still apply")
        #expect(lib.search(query: "bench").map(\.id) == ["0025", "0314"], "English search unchanged")
        #expect(lib.search(query: "bankdrücken pulldown").isEmpty, "words from two different names don't combine")
    }

    @Test func otherNamesSurviveMergingCustomExercises() {
        let custom = Exercise(id: "custom-1", name: "my press", bodyPart: "chest", equipment: "band", target: "pectorals",
                              isCustom: true)
        let lib = ExerciseLibrary(exercises: Self.sample, otherNames: Self.otherNames).merging(custom: [custom])
        #expect(lib.search(query: "Bankdrücken").map(\.id) == ["0025"])
        #expect(lib.otherNames(for: "0025").first == "Bankdrücken LH")
        #expect(lib.otherNames(for: "custom-1").isEmpty)
    }

    @Test func exactOtherNameLookupIsNormalizedAndUnambiguous() {
        let lib = ExerciseLibrary(exercises: Self.sample, otherNames: Self.otherNames)
        #expect(lib.exerciseId(forOtherName: "bankdrücken  lh") == "0025")
        #expect(lib.exerciseId(forOtherName: "Press-de-Banca!") == "0025")
        #expect(lib.exerciseId(forOtherName: "Bankdrücken") == nil, "exact name only, no partial match")
        #expect(lib.exerciseId(forOtherName: "Latziehen") == nil, "two exercises share it: ambiguous")
        #expect(lib.exerciseId(forOtherName: "bankdrucken lh") == nil, "import matching keeps diacritics exact")
    }

    @Test func searchOnlyNamesAreFoundButNeverImportAliases() {
        let lib = ExerciseLibrary(exercises: Self.sample, otherNames: ["0025": ["Abdominales", "Bankdrücken LH"]],
                                  importNames: ["0025": ["Bankdrücken LH"]])
        #expect(lib.search(query: "abdominales").map(\.id) == ["0025"])
        #expect(lib.exerciseId(forOtherName: "Abdominales") == nil)
        #expect(lib.exerciseId(forOtherName: "Bankdrücken LH") == "0025")
        #expect(lib.merging(custom: []).exerciseId(forOtherName: "Abdominales") == nil, "kept through merging")
    }

    @Test func otherNamesForUnknownIdsAreIgnored() {
        let lib = ExerciseLibrary(exercises: Self.sample, otherNames: ["9999": ["Geister"]])
        #expect(lib.search(query: "geister").isEmpty)
        #expect(lib.exerciseId(forOtherName: "Geister") == nil)
    }

    @Test func loadsBundledJSON() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() // GymData
            .deletingLastPathComponent().deletingLastPathComponent()                             // ios
            .appendingPathComponent("GymRollins/Resources/exercises.json")
        let lib = try ExerciseLibrary.load(from: url)
        #expect(lib.exercises.count == 1_324)
        #expect(lib.exercise("0025")?.name == "barbell bench press")
    }
}
