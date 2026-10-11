import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Shared loaders for the import tests: the synthetic Fitbod fixture, the bundled library and alias table.
enum ImportFixtures {
    private final class BundleToken {}

    static func sampleCSV() throws -> String {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "fitbod-sample", withExtension: "csv"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func library() throws -> ExerciseLibrary {
        try ExerciseLibrary.load(from: #require(Bundle.main.url(forResource: "exercises", withExtension: "json")))
    }

    static func samplePlan(library: ExerciseLibrary? = nil) throws -> ImportPlan {
        let lib = try library ?? Self.library()
        return ImportPlan.make(result: try FitbodImporter.parse(sampleCSV()), library: lib,
                               aliases: try FitbodAliases.load(), matcher: ExerciseMatcher(library: lib.exercises))
    }
}

@Suite struct ImportPlanTests {
    @Test func statsCountWorkoutsSetsWarmupsAndErrors() throws {
        let plan = try ImportFixtures.samplePlan()
        #expect(plan.stats.workouts == 3)
        #expect(plan.stats.sets == 28)
        #expect(plan.stats.warmupSets == 1)
        #expect(plan.stats.rowErrors.map(\.line) == [17])
        let range = try #require(plan.stats.dateRange)
        #expect(range.lowerBound == Date(timeIntervalSince1970: 1_767_636_000)) // 2026-01-05 18:00 UTC
        #expect(range.upperBound == Date(timeIntervalSince1970: 1_767_942_000)) // 2026-01-09 07:00 UTC
    }

    @Test func namesKeepFirstAppearanceOrder() throws {
        let plan = try ImportFixtures.samplePlan()
        #expect(plan.names == ["Barbell Bench Press", "Lat Pulldown", "Clam", "Dumbbell Biceps Curls", "Walking",
                               "Barbell Deadlift", "Zorblax Press", "Handle Band Row", "Swimming"])
    }

    @Test func aliasTableWinsThenMatcherThenSuggestion() throws {
        let plan = try ImportFixtures.samplePlan()
        #expect(plan.resolved("Barbell Bench Press") == .library("0025")) // alias
        #expect(plan.resolved("Lat Pulldown") == .library("0198"))        // alias beats the matcher's no-match
        #expect(plan.resolved("Walking") == .library("3666"))             // alias to cardio
        #expect(plan.resolved("Clam") == .custom)                         // alias null
        #expect(plan.resolved("Handle Band Row") == .custom)
        #expect(plan.resolved("Barbell Deadlift") == .library("0032"))    // matcher exact, not in the table
        #expect(plan.resolved("Dumbbell Biceps Curls") == .needsChoice(suggestion: "0294")) // fuzzy
        #expect(plan.resolved("Zorblax Press") == .needsChoice(suggestion: nil))
        #expect(plan.needsChoice == ["Dumbbell Biceps Curls", "Zorblax Press"])
    }

    @Test func aliasKeysMatchAfterNormalization() throws {
        let lib = try ImportFixtures.library()
        let csv = """
        Date,Exercise,Reps,Weight(kg),Duration(s),Distance(m),Incline,Resistance,isWarmup,Note,multiplier
        2026-01-05 18:00:00 +0000,lat  pulldown,10,50.0,0.0,0.0,0.0,0.0,false,,1.0
        """
        let plan = ImportPlan.make(result: try FitbodImporter.parse(csv), library: lib,
                                   aliases: ["Lat Pulldown": "0198"], matcher: ExerciseMatcher(library: lib.exercises))
        #expect(plan.resolved("lat  pulldown") == .library("0198"))
    }

    @Test func aliasToUnknownIdFallsBackToMatcher() throws {
        let lib = try ImportFixtures.library()
        let csv = """
        Date,Exercise,Reps,Weight(kg),Duration(s),Distance(m),Incline,Resistance,isWarmup,Note,multiplier
        2026-01-05 18:00:00 +0000,Barbell Deadlift,5,100.0,0.0,0.0,0.0,0.0,false,,1.0
        """
        let plan = ImportPlan.make(result: try FitbodImporter.parse(csv), library: lib,
                                   aliases: ["Barbell Deadlift": "9999"], matcher: ExerciseMatcher(library: lib.exercises))
        #expect(plan.resolved("Barbell Deadlift") == .library("0032"))
    }

    @Test func unknownNameIsNeedsChoice() throws {
        let plan = try ImportFixtures.samplePlan()
        #expect(plan.resolved("Not In The File") == .needsChoice(suggestion: nil))
    }
}
