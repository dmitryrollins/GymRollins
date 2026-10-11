import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymRollins

extension ImportFixtures {
    private final class Token {}

    /// `Fixtures/<app>-sample.csv` (synthetic, no personal data).
    static func sampleCSV(_ source: ImportSource) throws -> String {
        let name = source == .fitNotes ? "fitnotes-sample" : "\(source.rawValue)-sample"
        let url = try #require(Bundle(for: Token.self).url(forResource: name, withExtension: "csv"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The sample export for `source` parsed with auto-detect (Strong's weights read as pounds) and matched.
    static func samplePlan(_ source: ImportSource, unit: WeightUnit = .lb) throws -> ImportPlan {
        let lib = try library()
        let result = try WorkoutImporters.parse(sampleCSV(source), source: nil, options: ImportOptions(weightUnit: unit))
        #expect(result.source == source)
        return ImportPlan.make(result: result, library: lib, aliases: try ImportAliases.load(source),
                               matcher: ExerciseMatcher(library: lib.exercises))
    }
}

/// Strong / Hevy / FitNotes sample exports through `ImportPlan` and `ImportService` into an in-memory store.
@MainActor
@Suite struct OtherAppsImportTests {
    private let container: ModelContainer
    private let workouts: WorkoutRepository
    private let customs: CustomExerciseRepository
    private let service: ImportService

    init() throws {
        container = try GymStore.container(inMemory: true)
        workouts = WorkoutRepository(context: container.mainContext)
        customs = CustomExerciseRepository(context: container.mainContext)
        service = ImportService(workouts: workouts, customExercises: customs, library: try ImportFixtures.library())
    }

    private func saved() throws -> [Workout] {
        try workouts.recent(limit: 1_000).sorted { $0.startedAt < $1.startedAt }
    }

    private func importSample(_ source: ImportSource) async throws -> ImportSummary {
        let plan = try ImportFixtures.samplePlan(source)
        let choices = Dictionary(uniqueKeysWithValues: plan.needsChoice.map { ($0, ImportPlan.Resolution.custom) })
        return try await service.importAll(plan: plan, choices: choices)
    }

    // MARK: Plans

    @Test(arguments: [(ImportSource.strong, "Zorblax Carry (Dumbbell)"), (.hevy, "Zorblax Carry (Dumbbell)"),
                      (.fitNotes, "Zorblax Carry")])
    func onlyTheMadeUpExerciseNeedsAChoice(_ source: ImportSource, unmatched: String) throws {
        #expect(try ImportFixtures.samplePlan(source).needsChoice == [unmatched])
    }

    @Test func strongPlanStats() throws {
        let stats = try ImportFixtures.samplePlan(.strong).stats
        #expect(stats.workouts == 3 && stats.sets == 18 && stats.warmupSets == 2)
        #expect(stats.rowErrors.map(\.line) == [13])
    }

    @Test func hevyPlanStats() throws {
        let stats = try ImportFixtures.samplePlan(.hevy).stats
        #expect(stats.workouts == 3 && stats.sets == 12 && stats.warmupSets == 2)
        #expect(stats.rowErrors.map(\.line) == [9])
    }

    @Test func fitNotesPlanStats() throws {
        let stats = try ImportFixtures.samplePlan(.fitNotes).stats
        #expect(stats.workouts == 2 && stats.sets == 10 && stats.warmupSets == 0)
        #expect(stats.rowErrors.map(\.line) == [8])
    }

    @Test func aliasesResolveTheSampleNames() throws {
        let strong = try ImportFixtures.samplePlan(.strong)
        #expect(strong.resolved("Bench Press (Barbell)") == .library("0025"))
        #expect(strong.resolved("Lat Pulldown (Cable)") == .library("0198"))
        let hevy = try ImportFixtures.samplePlan(.hevy)
        #expect(hevy.resolved("Bicep Curl (Dumbbell)") == .library("0294"))
        #expect(hevy.resolved("Running") == .library("0685"))
        let fitNotes = try ImportFixtures.samplePlan(.fitNotes)
        #expect(fitNotes.resolved("Flat Barbell Bench Press") == .library("0025"))
        #expect(fitNotes.resolved("Barbell Squat") == .library("0043"))
    }

    // MARK: Import

    @Test func strongWorkoutsKeepNamesNotesDurationsAndUnits() async throws {
        let summary = try await importSample(.strong)
        #expect(summary.workouts == 3 && summary.sets == 18 && summary.duplicatesSkipped == 0)
        #expect(summary.createdExercises.map(\.name) == ["Zorblax Carry (Dumbbell)"])
        let all = try saved()
        #expect(all.map(\.name) == ["Push, heavy", "Legs", "Pull"])
        #expect(all.allSatisfy { $0.source == .import })
        let push = all[0]
        #expect(push.note == "Imported from Strong\nSlept well, felt good")
        #expect(push.endedAt == push.startedAt.addingTimeInterval(65 * 60))
        let bench = try #require(push.entries.first { $0.exerciseId == "0025" })
        #expect(bench.sets.map(\.warmup) == [true, false, false, false])
        #expect(abs(bench.sets[1].weightKg - 61.235) < 0.001)
        #expect(bench.sets[1].rpe == 8)
        #expect(bench.note == "Paused, 1s")
        let legs = all[1]
        #expect(legs.entries.first { $0.exerciseId == "0685" }?.sets.first?.distanceM == 1_600)
        #expect(legs.entries.first { $0.exerciseId == "2135" }?.sets.first?.sec == 60)
    }

    @Test func hevyWorkoutsKeepSupersetsAndEndTimes() async throws {
        let summary = try await importSample(.hevy)
        #expect(summary.workouts == 3 && summary.sets == 12)
        let upper = try #require(try saved().first)
        #expect(upper.name == "Upper, A")
        #expect(upper.note == "Imported from Hevy\nChest focus")
        #expect(upper.endedAt == upper.startedAt.addingTimeInterval(70 * 60))
        #expect(upper.entries.map(\.supersetGroup) == [nil, "1", "1"])
        #expect(upper.entries[0].sets.map(\.weightKg) == [40, 80, 60])
    }

    @Test func fitNotesDaysBecomeNoonWorkouts() async throws {
        let summary = try await importSample(.fitNotes)
        #expect(summary.workouts == 2 && summary.sets == 10)
        let all = try saved()
        #expect(all.allSatisfy { $0.name == "FitNotes workout" && $0.note == "Imported from FitNotes" })
        #expect(all.allSatisfy { Calendar.current.component(.hour, from: $0.startedAt) == 12 })
        #expect(all[0].endedAt == all[0].startedAt.addingTimeInterval(ImportService.assumedDuration))
    }

    @Test(arguments: [ImportSource.strong, .hevy, .fitNotes])
    func reimportIsIdempotent(_ source: ImportSource) async throws {
        let first = try await importSample(source)
        let second = try await importSample(source)
        #expect(second.workouts == first.workouts && second.duplicatesSkipped == 0)
        #expect(second.createdExercises.isEmpty)
        #expect(try saved().count == first.workouts)
        #expect(try saved().flatMap(\.entries).flatMap(\.sets).count == first.sets)
    }

    /// The same three sessions exported from Strong and from Hevy (e.g. after moving apps) import once.
    @Test func sameSessionsFromAnotherAppAreSkipped() async throws {
        _ = try await importSample(.strong)
        let hevy = try await importSample(.hevy)
        #expect(hevy.duplicatesSkipped == 3)
        #expect(hevy.workouts == 0 && hevy.sets == 0)
        #expect(try saved().map(\.name) == ["Push, heavy", "Legs", "Pull"])
    }

    /// Imported names are free text from another app; the CSV export must still neutralize formula-like ones.
    @Test func importedFormulaNamesAreNeutralizedOnExport() async throws {
        let csv = """
        Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,Notes,Workout Notes,RPE
        2026-01-05 18:00:00,Push,1h,"=HYPERLINK(""http://x"")",1,100,5,0,0,@SUM(A1),,
        """
        let lib = try ImportFixtures.library()
        let result = try WorkoutImporters.parse(csv, source: .strong, options: ImportOptions(weightUnit: .kg))
        let plan = ImportPlan.make(result: result, library: lib, aliases: try ImportAliases.load(.strong),
                                   matcher: ExerciseMatcher(library: lib.exercises))
        _ = try await service.importAll(plan: plan, choices: [plan.names[0]: .custom])
        let context = container.mainContext
        let customNames = Dictionary(uniqueKeysWithValues: try customs.all().map { ($0.id, $0.name) })
        let export = ExportService(profiles: ProfileRepository(context: context),
                                   routines: RoutineRepository(context: context), workouts: workouts,
                                   body: BodyRepository(context: context), customExercises: customs,
                                   proposals: ProposalRepository(context: context),
                                   exerciseName: { customNames[$0] ?? lib.exercise($0)?.name ?? $0 })
        let out = try export.workoutsCSV()
        #expect(out.contains("'=HYPERLINK"))
        #expect(out.contains("'@SUM(A1)"))
        #expect(!out.contains(",=") && !out.contains(",@"))
    }

    /// A custom-only name that appears just in a skipped duplicate workout must not create an exercise (it would be
    /// created with no sets to infer its mode from, e.g. a rowing machine as a reps exercise).
    @Test func namesOnlyInSkippedDuplicatesCreateNoExercises() async throws {
        _ = try await importSample(.strong)
        let csv = """
        title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,set_type,\
        weight_kg,reps,distance_km,duration_seconds,rpe
        "Push","5 Jan 2026, 18:00","5 Jan 2026, 19:00","","Rowing Machine",,"",0,"normal",,,2,600,
        "Later","6 Jan 2026, 18:00","6 Jan 2026, 19:00","","Bench Press (Barbell)",,"",0,"normal",60,8,,,
        """
        let lib = try ImportFixtures.library()
        let result = try WorkoutImporters.parse(csv, source: .hevy)
        let plan = ImportPlan.make(result: result, library: lib, aliases: try ImportAliases.load(.hevy),
                                   matcher: ExerciseMatcher(library: lib.exercises))
        let summary = try await service.importAll(plan: plan)
        #expect(summary.duplicatesSkipped == 1 && summary.workouts == 1)
        #expect(summary.createdExercises.isEmpty)
        #expect(try customs.all().allSatisfy { $0.name != "Rowing Machine" })
    }

    /// Strong / Hevy / FitNotes log a dumbbell's weight per hand, like the app's own logging: library dumbbell
    /// exercises get multiplier 2 (as `SessionPlanner.multiplier(for:)`), everything else 1.
    @Test func dumbbellExercisesGetThePairMultiplier() async throws {
        _ = try await importSample(.hevy)
        let upper = try #require(try saved().first)
        #expect(upper.entries.first { $0.exerciseId == "0294" }?.sets.map(\.multiplier) == [2]) // dumbbell curl
        #expect(upper.entries.first { $0.exerciseId == "0025" }?.sets.allSatisfy { $0.multiplier == 1 } == true)
    }

    /// Movements done with one dumbbell (goblet squat, two-hand overhead extension, one-arm work) keep multiplier 1.
    @Test func singleDumbbellMovementsAreNotDoubled() throws {
        let lib = try ImportFixtures.library()
        let multiplier = { (id: String) in ImportService.pairMultiplier(for: lib.exercise(id)) }
        #expect(multiplier("1760") == 1) // dumbbell goblet squat
        #expect(multiplier("2188") == 1) // dumbbell seated triceps extension (one dumbbell, both hands)
        #expect(multiplier("0292") == 1) // dumbbell one arm bent-over row
        #expect(multiplier("0297") == 1) // dumbbell concentration curl
        #expect(multiplier("0375") == 1) // dumbbell pullover (one dumbbell, both hands)
        #expect(multiplier("0407") == 1) // dumbbell side bend
        #expect(multiplier("0294") == 2) // dumbbell biceps curl
        #expect(multiplier("0334") == 2) // dumbbell lateral raise
        #expect(multiplier("0025") == 1) // barbell bench press
        #expect(ImportService.pairMultiplier(for: nil) == 1)
        // A custom exercise follows its own "uses both dumbbells" setting, like logging in the app.
        let custom = { (bilateral: Bool) in
            Exercise(id: "custom-x", name: "Zorblax Curl", bodyPart: "upper arms", equipment: "dumbbell",
                     target: "biceps", isCustom: true, bilateral: bilateral)
        }
        #expect(ImportService.pairMultiplier(for: custom(true)) == 2)
        #expect(ImportService.pairMultiplier(for: custom(false)) == 1)
    }

    /// FitNotes days carry a made-up noon start, so they never count as the same session as a timed workout.
    @Test func dateOnlyWorkoutsAreNotProximityDuplicates() async throws {
        let noon = try #require(try ImportFixtures.samplePlan(.fitNotes).result.workouts.first?.startedAt)
        try workouts.save(Workout(startedAt: noon, endedAt: noon.addingTimeInterval(3_600),
                                  name: "Lunch session"))
        let fitNotes = try await importSample(.fitNotes)
        #expect(fitNotes.duplicatesSkipped == 0 && fitNotes.workouts == 2)
        // ...and the other way round: a timed import next to an imported FitNotes day is kept.
        let timed = """
        \(Self.hevyKgHeader)
        "Noon","\(Self.hevyDate(noon.addingTimeInterval(-30)))","","","Bench Press (Barbell)",,"",0,"normal",60,8,,,
        """
        let lib = try ImportFixtures.library()
        let result = try WorkoutImporters.parse(timed, source: .hevy)
        let plan = ImportPlan.make(result: result, library: lib, aliases: try ImportAliases.load(.hevy),
                                   matcher: ExerciseMatcher(library: lib.exercises))
        let hevy = try await service.importAll(plan: plan)
        // Only the app's "Lunch session" (a real timed workout) makes it a duplicate.
        #expect(hevy.duplicatesSkipped == 1)
        try workouts.delete(try #require(try saved().first { $0.name == "Lunch session" }).id)
        let again = try await service.importAll(plan: plan)
        #expect(again.duplicatesSkipped == 0 && again.workouts == 1)
    }

    private static let hevyKgHeader = "title,start_time,end_time,description,exercise_title,superset_id,"
        + "exercise_notes,set_index,set_type,weight_kg,reps,distance_km,duration_seconds,rpe"

    private static func hevyDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f.string(from: date)
    }
}
