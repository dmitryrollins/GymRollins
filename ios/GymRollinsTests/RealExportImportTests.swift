#if DEBUG
import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Local-only dry run against the owner's real Fitbod export. Skipped unless `GYM_REAL_EXPORT` points at the CSV
/// (from xcodebuild: `TEST_RUNNER_GYM_REAL_EXPORT=/path/to/WorkoutExport.csv scripts/ios-test.sh ...`).
/// The CSV is never committed, and this test prints counts only — no names, dates, weights or notes.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GYM_REAL_EXPORT"] != nil))
struct RealExportImportTests {
    @Test func ownerExportResolvesEveryNameAndImportsQuickly() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["GYM_REAL_EXPORT"])
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        let library = try ImportFixtures.library()
        let plan = ImportPlan.make(result: try FitbodImporter.parse(text), library: library,
                                   aliases: try FitbodAliases.load(), matcher: ExerciseMatcher(library: library.exercises))
        #expect(plan.needsChoice.isEmpty, "Unresolved names: \(plan.needsChoice.count)")
        // The export's own workouts (`stats.workouts` counts a split one once); none of the owner's is past the caps.
        #expect(plan.stats.workouts == 142)
        #expect(plan.stats.rowErrors.isEmpty)
        #expect(plan.stats.warmupSets == 185)

        let container = try GymStore.container(inMemory: true)
        let workouts = WorkoutRepository(context: container.mainContext)
        let service = ImportService(workouts: workouts,
                                    customExercises: CustomExerciseRepository(context: container.mainContext))
        let clock = ContinuousClock()
        let started = clock.now
        let summary = try await service.importAll(plan: plan)
        let elapsed = clock.now - started
        // One stored row per piece (`ImportSplit`), while the summary counts the export's workouts, as the preview does.
        #expect(try workouts.recent(limit: 10_000).count == plan.result.workouts.count)
        #expect(summary.workouts == plan.stats.workouts)
        #expect(summary.duplicatesSkipped == 0)
        #expect(elapsed < .seconds(5))
        print("RealExportImport: names=\(plan.names.count) workouts=\(summary.workouts) " +
              "pieces=\(plan.result.workouts.count) sets=\(summary.sets) " +
              "warmups=\(summary.warmupSets) rowErrors=\(summary.rowErrors.count) " +
              "customCreated=\(summary.createdExercises.count) unresolved=\(plan.needsChoice.count) elapsed=\(elapsed)")
    }
}
#endif
