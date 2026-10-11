import Foundation
import Testing
@testable import GymCore

@Suite struct StrongImporterTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let header = "Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,Notes,Workout Notes,RPE"
    static let sample = """
    \u{FEFF}\(header)
    2026-01-05 18:00:00,"Push, heavy",1h 5m,Bench Press (Barbell),W,95,10,0,0,,"Slept well, felt good",
    2026-01-05 18:00:00,"Push, heavy",1h 5m,Bench Press (Barbell),1,135,8,0,0,,"Slept well, felt good",8
    2026-01-05 18:00:00,"Push, heavy",1h 5m,Bench Press (Barbell),2,135,8,0,0,"Paused, 1s","Slept well, felt good",8.5
    2026-01-05 18:00:00,"Push, heavy",1h 5m,Bench Press (Barbell),D,115,10,0,0,,"Slept well, felt good",
    2026-01-05 18:00:00,"Push, heavy",1h 5m,Bench Press (Barbell),Rest Timer,0,0,0,90,,"Slept well, felt good",
    2026-01-05 18:00:00,"Push, heavy",1h 5m,Lateral Raise (Dumbbell),F,20,9,0,0,,"Slept well, felt good",

    2026-01-07 07:30:00,Legs,45m,Plank,1,0,0,0,60,,,
    2026-01-07 07:30:00,Legs,45m,Running (Treadmill),1,0,0,1600,600,,,
    2026-01-07 07:30:00,Legs,45m,Squat (Barbell),1,abc,5,0,0,,,
    2026-01-07 07:30:00,Legs,45m,Squat (Barbell),2,185,5,0,0,,,
    not-a-date,Legs,45m,Squat (Barbell),3,185,5,0,0,,,
    2026-01-07 07:30:00,Legs,45m,,1,185,5,0,0,,,
    2026-01-07 07:30:00,Legs,45m,Squat (Barbell),3,185,5.5,0,0,,,
    2026-01-07 07:30:00,Legs,45m,Squat (Barbell),4,185,0,0,0,,,
    """

    private func parse(_ text: String = sample, unit: WeightUnit = .lb) throws -> WorkoutImportResult {
        try StrongImporter.parse(text, options: ImportOptions(weightUnit: unit, timeZone: Self.utc))
    }

    @Test func recognizesCurrentAndOlderHeaders() throws {
        #expect(StrongImporter.recognizes(header: Self.header.components(separatedBy: ",")))
        #expect(StrongImporter.recognizes(header: ["Date", "Workout Name", "Duration", "Exercise Name", "Set Order",
                                                   "Weight", "Reps", "Distance", "Seconds", "RPE"]))
        let android = "Date;Workout Name;Exercise Name;Set Order;Weight;Weight Unit;Reps;RPE;Distance;Distance Unit;"
            + "Seconds;Notes;Workout Notes;Workout Duration"
        #expect(StrongImporter.recognizes(header: android.components(separatedBy: ";")))
        #expect(!StrongImporter.recognizes(header: FitbodImporter.expectedHeader))
        #expect(WorkoutImporters.detect(Self.sample) == .strong)
        #expect(WorkoutImporters.detect(android + "\n") == .strong)
    }

    @Test func needsWeightUnitOnlyWithoutUnitColumn() {
        #expect(StrongImporter.needsWeightUnit(header: Self.header.components(separatedBy: ",")))
        #expect(!StrongImporter.needsWeightUnit(header: ["Date", "Workout Name", "Exercise Name", "Set Order", "Weight",
                                                         "Weight Unit", "Reps"]))
        #expect(WorkoutImporters.needsWeightUnit(Self.sample, source: nil))
    }

    @Test func groupsByStartAndTitleWithNameNoteAndDuration() throws {
        let result = try parse()
        #expect(result.source == .strong)
        #expect(result.workouts.count == 2)
        let push = result.workouts[0]
        #expect(push.name == "Push, heavy")
        #expect(push.note == "Slept well, felt good")
        #expect(push.startedAt == Date(timeIntervalSince1970: 1_767_636_000)) // 2026-01-05 18:00 UTC
        #expect(push.endedAt == push.startedAt.addingTimeInterval(65 * 60))
        #expect(push.entries.map(\.exerciseName) == ["Bench Press (Barbell)", "Lateral Raise (Dumbbell)"])
        #expect(result.workouts[1].endedAt == result.workouts[1].startedAt.addingTimeInterval(45 * 60))
    }

    @Test func convertsPoundsAndMapsSetOrderCodes() throws {
        let bench = try parse().workouts[0].entries[0].sets
        #expect(bench.count == 4) // the Rest Timer row is not a set
        #expect(bench.map(\.warmup) == [true, false, false, false])
        #expect(abs(bench[1].weightKg - 61.235) < 0.001)
        #expect(bench[1].rpe == 8)
        #expect(bench[2].rpe == 8.5)
        #expect(bench[2].note == "Paused, 1s")
        #expect(bench[3].reps == 10) // drop set = working set
        #expect(try parse().warmupSetCount == 1)
    }

    @Test func kilogramOptionKeepsWeights() throws {
        #expect(try parse(unit: .kg).workouts[0].entries[0].sets[1].weightKg == 135)
    }

    @Test func timedAndDistanceSets() throws {
        let legs = try parse().workouts[1].entries
        let plank = try #require(legs.first { $0.exerciseName == "Plank" }?.sets.first)
        #expect(plank.durationSec == 60 && plank.reps == 0 && plank.distanceM == nil)
        let run = try #require(legs.first { $0.exerciseName == "Running (Treadmill)" }?.sets.first)
        #expect(run.distanceM == 1_600 && run.durationSec == 600)
    }

    @Test func reportsMalformedRowsAndIgnoresNonSets() throws {
        let result = try parse()
        #expect(result.rowErrors.map(\.line) == [11, 13, 14, 15])
        #expect(result.rowErrors.map(\.message) == ["Unreadable number in row", "Unreadable date 'not-a-date'",
                                                    "Missing exercise name", "Reps must be a whole number"])
        #expect(result.ignoredRowCount == 2) // Rest Timer + the 0-rep set
        #expect(result.rowCount == 14)
        let squats = try #require(result.workouts[1].entries.first { $0.exerciseName == "Squat (Barbell)" })
        #expect(squats.sets.count == 1)
    }

    @Test func idsAreDeterministicAndDistinctFromOtherApps() throws {
        let a = try parse()
        let b = try parse(unit: .kg)
        #expect(a.workouts.map(\.id) == b.workouts.map(\.id))
        #expect(Set(a.workouts.map(\.id)).count == 2)
    }

    @Test func androidSemicolonExportWithUnitsAndDecimalCommas() throws {
        let text = """
        Date;Workout Name;Exercise Name;Set Order;Weight;Weight Unit;Reps;RPE;Distance;Distance Unit;Seconds;Notes;\
        Workout Notes;Workout Duration
        2026-02-02 17:45:00;Oberkörper;Bench Press (Barbell);W;40;kg;10;;0;;0;;;1h 10m
        2026-02-02 17:45:00;Oberkörper;Bench Press (Barbell);1;62,5;kg;8;8;0;;0;"Grip; wide";;1h 10m
        2026-02-02 17:45:00;Oberkörper;Curl (Dumbbell);1;30;lbs;10;;0;;0;;;1h 10m
        2026-02-02 17:45:00;Oberkörper;Cycling (Indoor);1;0;kg;0;;5,5;km;900;;;1h 10m
        """
        let result = try parse(text, unit: .lb) // per-row units win over the option
        #expect(result.rowErrors.isEmpty)
        let workout = try #require(result.workouts.first)
        #expect(workout.name == "Oberkörper")
        #expect(workout.endedAt == workout.startedAt.addingTimeInterval(70 * 60))
        let bench = workout.entries[0].sets
        #expect(bench[1].weightKg == 62.5 && bench[1].note == "Grip; wide" && bench[0].warmup)
        #expect(abs(workout.entries[1].sets[0].weightKg - 13.608) < 0.001)
        #expect(workout.entries[2].sets[0].distanceM == 5_500 && workout.entries[2].sets[0].durationSec == 900)
    }

    @Test func durationFormats() {
        #expect(StrongImporter.durationSeconds("1h 5m") == 3_900)
        #expect(StrongImporter.durationSeconds("41m") == 2_460)
        #expect(StrongImporter.durationSeconds("2h") == 7_200)
        #expect(StrongImporter.durationSeconds("45s") == 45)
        #expect(StrongImporter.durationSeconds("1:02:03") == 3_723)
        #expect(StrongImporter.durationSeconds("42:15") == 2_535)
        #expect(StrongImporter.durationSeconds("") == nil)
        #expect(StrongImporter.durationSeconds("soon") == nil)
        #expect(StrongImporter.durationSeconds("5") == nil)
        #expect(StrongImporter.durationSeconds("99999999999999999999h") == nil) // no overflow trap
        #expect(StrongImporter.durationSeconds("9999999999999999:00:00") == nil)
    }

    @Test func outOfRangeValuesAreRowErrors() throws {
        let text = """
        \(Self.header)
        2026-01-05 18:00:00,Push,1h,Bench Press (Barbell),1,5000,8,0,0,,,
        2026-01-05 18:00:00,Push,1h,Bench Press (Barbell),2,100,8,0,0,,,11
        2026-01-05 18:00:00,Push,1h,Bench Press (Barbell),3,-5,8,0,0,,,
        2026-01-05 18:00:00,Push,1h,Bench Press (Barbell),4,100,8,0,999999,,,
        """
        let result = try parse(text, unit: .kg)
        #expect(result.rowErrors.map(\.line) == [2, 3, 4, 5])
        #expect(result.rowErrors.allSatisfy { $0.message == "Value out of range" })
    }

    @Test func shortRowsAreRowErrorsNotCrashes() throws {
        let text = "\(Self.header)\n2026-01-05 18:00:00,Push\n"
        let result = try parse(text)
        #expect(result.workouts.isEmpty)
        #expect(result.rowErrors.first?.line == 2)
    }

    @Test func missingRequiredColumnIsUnrecognized() {
        #expect(throws: WorkoutImportError.unrecognizedHeader(["Date", "Workout Name", "Exercise Name"])) {
            try StrongImporter.parse("Date,Workout Name,Exercise Name\n", options: ImportOptions())
        }
    }
}
