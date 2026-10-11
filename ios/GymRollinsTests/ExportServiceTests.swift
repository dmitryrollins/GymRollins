import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymRollins

/// Serialized: the export-file tests share `ExportService.exportDirectory`.
@MainActor
@Suite(.serialized) struct ExportServiceTests {
    private let container: ModelContainer
    private let profiles: ProfileRepository
    private let routines: RoutineRepository
    private let workouts: WorkoutRepository
    private let body: BodyRepository
    private let customExercises: CustomExerciseRepository
    private let proposals: ProposalRepository
    private let library: ExerciseLibrary
    private let service: ExportService

    init() throws {
        container = try GymStore.container(inMemory: true)
        let context = container.mainContext
        library = try ImportFixtures.library()
        profiles = ProfileRepository(context: context)
        routines = RoutineRepository(context: context)
        workouts = WorkoutRepository(context: context)
        body = BodyRepository(context: context)
        customExercises = CustomExerciseRepository(context: context)
        proposals = ProposalRepository(context: context)
        let lib = library
        service = ExportService(profiles: profiles, routines: routines, workouts: workouts, body: body,
                                customExercises: customExercises, proposals: proposals,
                                exerciseName: { lib.exercise($0)?.name ?? $0 })

        try routines.upsert(Routine(name: "Push", exercises: [
            RoutineExercise(exerciseId: "0025", sets: 3, reps: 8, weightKg: 60),
        ]))
        try routines.setSchedule(weekday: 1, routineId: try routines.all()[0].id)
        try body.add(BodyweightEntry(date: Date(timeIntervalSince1970: 1_767_600_000), weightKg: 81))
        try customExercises.create(name: "Band Pull-Apart", bodyPart: "back", equipment: "band", target: "back",
                                   mode: .reps, bilateral: true)
        try workouts.save(Workout(startedAt: Date(timeIntervalSince1970: 1_767_600_000), name: "Push",
                                  entries: [WorkoutEntry(exerciseId: "0025", sets: [
                                      WorkoutSet(weightKg: 60, reps: 8, done: true, warmup: true),
                                      WorkoutSet(weightKg: 62.5, reps: 8, done: true),
                                  ])], source: .app))
        try workouts.save(Workout(startedAt: Date(timeIntervalSince1970: 1_767_700_000), name: "Cardio",
                                  entries: [WorkoutEntry(exerciseId: "3666", sets: [
                                      WorkoutSet(weightKg: 0, reps: 0, sec: 1_200, distanceM: 1_500, done: true),
                                  ])], source: .app))
    }

    // MARK: JSON backup

    @Test func jsonBackupRoundTripsCounts() throws {
        let data = try service.backupData()
        let decoded = try JSONDecoder.gymRollinsISO8601().decode(ExportBackup.self, from: data)
        #expect(decoded.version == ExportBackup.currentVersion)
        #expect(decoded.routines.count == 1)
        #expect(decoded.schedule["1"] != nil)
        #expect(decoded.workouts.count == 2)
        #expect(decoded.bodyweight.count == 1)
        #expect(decoded.customExercises.count == 1)
        #expect(decoded.profile.unit == .lb)
    }

    @Test func jsonBackupIncludesWeeklyTargets() throws {
        let targets = MuscleTargetRepository(context: container.mainContext)
        try targets.set(.chest, SetTargetRange(min: 12, max: 18))
        var withTargets = service
        withTargets.muscleTargets = targets
        let decoded = try JSONDecoder.gymRollinsISO8601().decode(ExportBackup.self, from: withTargets.backupData())
        #expect(decoded.weeklyTargets?["chest"] == SetTargetRange(min: 12, max: 18))
        #expect(decoded.weeklyTargets?["biceps"] == MuscleGroup.biceps.defaultTarget)
        #expect(decoded.weeklyTargets?.count == MuscleGroup.allCases.count)
    }

    @Test func jsonBackupIncludesExercisePreferences() throws {
        let prefs = ExercisePreferenceRepository(context: container.mainContext)
        try prefs.set(.more, for: "0025")
        try prefs.set(.never, for: "0070")
        var withPrefs = service
        withPrefs.exercisePreferences = prefs
        let decoded = try JSONDecoder.gymRollinsISO8601().decode(ExportBackup.self, from: withPrefs.backupData())
        #expect(decoded.exercisePreferences == ["0025": .more, "0070": .never])
    }

    @Test func jsonBackupPreservesWorkoutDetail() throws {
        let backup = try service.backup()
        let push = try #require(backup.workouts.first { $0.name == "Push" })
        #expect(push.entries.first?.sets.map(\.warmup) == [true, false])
        #expect(push.entries.first?.sets.map(\.weightKg) == [60, 62.5])
    }

    // MARK: Fitbod CSV

    @Test func csvHeaderMatchesFitbodImporter() throws {
        let csv = try service.workoutsCSV()
        let firstLine = try #require(csv.components(separatedBy: "\r\n").first)
        #expect(firstLine == FitbodImporter.expectedHeader.joined(separator: ","))
    }

    @Test func csvRoundTripsThroughFitbodImporter() throws {
        let csv = try service.workoutsCSV()
        let result = try FitbodImporter.parse(csv)
        #expect(result.rowErrors.isEmpty)
        #expect(result.workouts.count == 2)
        #expect(result.warmupSetCount == 1)
        let push = try #require(result.workouts.first { $0.entries.first?.exerciseName == "barbell bench press" })
        #expect(push.entries[0].sets.map(\.weightKg) == [60, 62.5])
        #expect(push.entries[0].sets.map(\.warmup) == [true, false])
        let cardio = try #require(result.workouts.first { $0.entries.first?.exerciseName == "walking on incline treadmill" })
        #expect(cardio.entries[0].sets[0].durationSec == 1_200)
        #expect(cardio.entries[0].sets[0].distanceM == 1_500)
    }

    @Test func csvRoundTripThroughImportPlanKeepsSameSetCount() throws {
        let csv = try service.workoutsCSV()
        let result = try FitbodImporter.parse(csv)
        let plan = ImportPlan.make(result: result, library: library, aliases: try FitbodAliases.load(),
                                   matcher: ExerciseMatcher(library: library.exercises))
        #expect(plan.needsChoice.isEmpty)
        #expect(plan.stats.sets == 3)
    }

    /// Entry notes are exported (CSV-escaped: commas, quotes, newlines) and come back through the importer.
    @Test func csvExportsEntryNotesAndRoundTripsThem() throws {
        let note = "Grip \"wide\", slow eccentric\nleft shoulder ok"
        try workouts.save(Workout(startedAt: Date(timeIntervalSince1970: 1_767_800_000), name: "Noted",
                                  entries: [WorkoutEntry(exerciseId: "0025", sets: [
                                      WorkoutSet(weightKg: 60, reps: 8, done: true),
                                      WorkoutSet(weightKg: 60, reps: 7, done: true),
                                  ], note: note)], source: .app))
        let csv = try service.workoutsCSV()
        #expect(csv.contains("\"Grip \"\"wide\"\", slow eccentric\nleft shoulder ok\""))
        let result = try FitbodImporter.parse(csv)
        #expect(result.rowErrors.isEmpty)
        let imported = try #require(result.workouts.first { $0.entries.first?.sets.first?.note != nil })
        let setNotes = imported.entries[0].sets.map { $0.note }
        #expect(setNotes == [note, note])
        let workout = ImportService.workout(from: imported, exerciseIds: ["barbell bench press": "0025"])
        #expect(workout.entries.first?.note == note)
        // Entries without a note still export an empty Note field.
        let otherNotes = result.workouts.filter { $0.id != imported.id }.flatMap { $0.entries }.flatMap { $0.sets }
            .compactMap { $0.note }
        #expect(otherNotes.isEmpty)
    }

    /// Security: a text field a spreadsheet would run as a formula (= + - @ tab CR) is exported with a leading `'`;
    /// numbers are untouched.
    @Test func csvNeutralizesFormulaInjection() throws {
        let formulaService = ExportService(profiles: profiles, routines: routines, workouts: workouts, body: body,
                                           customExercises: customExercises, proposals: proposals,
                                           exerciseName: { $0 == "custom-formula" ? "=1+1" : $0 })
        try workouts.save(Workout(startedAt: Date(timeIntervalSince1970: 1_767_800_000), name: "Formula",
                                  entries: [WorkoutEntry(exerciseId: "custom-formula", sets: [
                                      WorkoutSet(weightKg: 60, reps: 8, done: true),
                                  ], note: "@SUM(A1)")], source: .app))
        let csv = try formulaService.workoutsCSV()
        let row = try #require(csv.components(separatedBy: "\r\n").first { $0.contains("1+1") })
        let fields = row.components(separatedBy: ",")
        #expect(fields[1] == "'=1+1")
        #expect(fields[2] == "8" && fields[3] == "60.0")
        #expect(fields[9] == "'@SUM(A1)")
        #expect(!csv.contains(",=") && !csv.contains(",@") && !csv.contains(",+"))
    }

    @Test(arguments: [("=cmd", "'=cmd"), ("+1", "'+1"), ("-2", "'-2"), ("@x", "'@x"), ("\tx", "'\tx"),
                      ("\rx", "\"'\rx\""), ("=a,b", "\"'=a,b\""), ("plain", "plain"), ("a=b", "a=b"), ("", "")])
    func csvFieldEscaping(input: String, expected: String) {
        #expect(ExportService.csvEscape(input) == expected)
    }

    /// Every export writes a fresh file from current data into the export folder, replacing the previous file;
    /// `removeExportFiles` (after sharing, sign-out, erase) leaves nothing behind.
    @Test func exportFilesAreRegeneratedAndRemovable() throws {
        let first = try service.writeWorkoutsCSVFile()
        let firstText = try String(contentsOf: first, encoding: .utf8)
        try workouts.save(Workout(startedAt: Date(timeIntervalSince1970: 1_767_900_000), name: "Later",
                                  entries: [WorkoutEntry(exerciseId: "0025", sets: [
                                      WorkoutSet(weightKg: 70, reps: 5, done: true),
                                  ])], source: .app))
        var later = service
        later.now = { Date(timeIntervalSince1970: 1_767_900_100) }
        let second = try later.writeWorkoutsCSVFile()
        let secondText = try String(contentsOf: second, encoding: .utf8)
        #expect(secondText.components(separatedBy: "\r\n").count == firstText.components(separatedBy: "\r\n").count + 1)
        #expect(second.deletingLastPathComponent().standardizedFileURL
            == ExportService.exportDirectory.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: first.path) || first == second)
        let backup = try later.writeBackupFile()
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: backup.path))

        ExportService.removeExportFiles()
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(!FileManager.default.fileExists(atPath: ExportService.exportDirectory.path))
    }

    /// Erasing local data removes any prepared export file too.
    @Test func eraseAllLocalDataRemovesExportFiles() throws {
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]))
        let url = try env.exportService().writeBackupFile()
        #expect(FileManager.default.fileExists(atPath: url.path))
        try env.eraseAllLocalData()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

private extension JSONDecoder {
    static func gymRollinsISO8601() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
