import Foundation
import Testing
@testable import GymCore

@Suite struct FitNotesImporterTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let header = "Date,Exercise,Category,Weight (kg),Weight (lbs),Reps,Distance,Distance Unit,Time,Notes,Kind"
    static let sample = """
    \(header)
    2026-01-05,Flat Barbell Bench Press,Chest,60.0,,8,,,,,wr
    2026-01-05,Flat Barbell Bench Press,Chest,60.0,,8,,,,"slow, controlled",wr
    2026-01-05,Dumbbell Curl,Biceps,,25,10,,,,,wr
    2026-01-05,Chin Up,Back,,,8,,,,,r
    2026-01-07,Plank,Abs,,,,,,01:00,,t
    2026-01-07,Running (Treadmill),Cardio,,,,5,km,25:30,,dt
    2026-01-07,Cycling,Cardio,,,,10,mi,1:00:00,,dt
    2026-01-07,Barbell Squat,Legs,100,,x,,,,,wr
    2026-01-07,Barbell Squat,Legs,100,,5,,,,,wr
    2026-13-45,Barbell Squat,Legs,100,,5,,,,,wr
    2026-01-07,Walk,Cardio,,,,400,parsecs,05:00,,dt
    2026-01-07,Barbell Squat,Legs,,,,,,,,
    """

    private func parse(_ text: String = sample) throws -> WorkoutImportResult {
        try FitNotesImporter.parse(text, options: ImportOptions(weightUnit: .kg, timeZone: Self.utc))
    }

    @Test func recognizesCurrentAndOlderHeaders() {
        #expect(FitNotesImporter.recognizes(header: Self.header.components(separatedBy: ",")))
        let android = ["Date", "Exercise", "Category", "Weight (kgs)", "Reps", "Distance", "Distance Unit", "Time"]
        #expect(FitNotesImporter.recognizes(header: android))
        #expect(!FitNotesImporter.needsWeightUnit(header: android))
        let unitless = ["Date", "Exercise", "Category", "Weight", "Reps", "Distance", "Distance Unit", "Time", "Comment"]
        #expect(FitNotesImporter.recognizes(header: unitless))
        #expect(FitNotesImporter.needsWeightUnit(header: unitless))
        #expect(!FitNotesImporter.recognizes(header: FitbodImporter.expectedHeader))
        #expect(WorkoutImporters.detect(Self.sample) == .fitNotes)
    }

    @Test func oneWorkoutPerDayAtNoon() throws {
        let result = try parse()
        #expect(result.source == .fitNotes)
        #expect(result.workouts.count == 2)
        #expect(result.workouts[0].startedAt == Date(timeIntervalSince1970: 1_767_614_400)) // 2026-01-05 12:00 UTC
        #expect(result.workouts[0].name == nil && result.workouts[0].endedAt == nil)
        #expect(result.workouts[0].entries.map(\.exerciseName) == ["Flat Barbell Bench Press", "Dumbbell Curl", "Chin Up"])
    }

    @Test func weightColumnsAndNotes() throws {
        let day = try parse().workouts[0].entries
        #expect(day[0].sets.map(\.weightKg) == [60, 60])
        #expect(day[0].sets[1].note == "slow, controlled")
        #expect(abs(day[1].sets[0].weightKg - 11.340) < 0.001) // Weight (lbs)
        #expect(day[2].sets[0].weightKg == 0 && day[2].sets[0].reps == 8)
        #expect(try parse().warmupSetCount == 0)
    }

    @Test func timesAndDistanceUnits() throws {
        let day = try parse().workouts[1].entries
        #expect(day[0].sets[0].durationSec == 60)
        #expect(day[1].sets[0].distanceM == 5_000 && day[1].sets[0].durationSec == 1_530)
        #expect(abs((day[2].sets[0].distanceM ?? 0) - 16_093.44) < 0.01 && day[2].sets[0].durationSec == 3_600)
    }

    @Test func malformedRowsAreReported() throws {
        let result = try parse()
        #expect(result.rowErrors.map(\.line) == [9, 11, 12])
        #expect(result.rowErrors.map(\.message) == ["Unreadable number in row", "Unreadable date '2026-13-45'",
                                                    "Unknown distance unit 'parsecs'"])
        #expect(result.ignoredRowCount == 1)
        #expect(result.workouts[1].entries.first { $0.exerciseName == "Barbell Squat" }?.sets.count == 1)
    }

    @Test func singleWeightColumnWithUnitColumn() throws {
        let text = """
        Date,Exercise,Category,Weight,Weight Unit,Reps,Distance,Distance Unit,Time,Comment
        2026-01-05,Deadlift,Back,225,lbs,5,,,,
        2026-01-05,Deadlift,Back,140,kgs,3,,,,top set
        """
        let sets = try #require(try parse(text).workouts.first?.entries.first?.sets)
        #expect(abs(sets[0].weightKg - 102.058) < 0.001)
        #expect(sets[1].weightKg == 140 && sets[1].note == "top set")
    }

    @Test func unitlessWeightUsesOption() throws {
        let text = "Date,Exercise,Category,Weight,Reps\n2026-01-05,Deadlift,Back,100,5\n"
        let lb = try FitNotesImporter.parse(text, options: ImportOptions(weightUnit: .lb, timeZone: Self.utc))
        #expect(abs((lb.workouts.first?.entries.first?.sets.first?.weightKg ?? 0) - 45.359) < 0.001)
    }

    @Test func timeFormats() {
        #expect(FitNotesImporter.seconds("01:00") == 60)
        #expect(FitNotesImporter.seconds("1:00:00") == 3_600)
        #expect(FitNotesImporter.seconds("0:00:30") == 30)
        #expect(FitNotesImporter.seconds("90") == 90)
        #expect(FitNotesImporter.seconds("") == nil)
        #expect(FitNotesImporter.seconds("1:xx") == nil)
        #expect(FitNotesImporter.seconds("1:75") == nil)
        #expect(FitNotesImporter.seconds("1e300") == nil) // no overflow trap
        #expect(FitNotesImporter.seconds("-5") == nil)
    }

    @Test func idsAreDeterministicPerDay() throws {
        let a = try parse()
        #expect(a.workouts.map(\.id) == (try parse()).workouts.map(\.id))
        #expect(Set(a.workouts.map(\.id)).count == 2)
    }

    /// São Paulo skipped local midnight on 2018-11-04 (DST); the day must still import, at noon.
    @Test func dateWhoseMidnightDoesNotExistStillParses() throws {
        let saoPaulo = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let text = "\(Self.header)\n2018-11-04,Deadlift,Back,100,,5,,,,,wr\n"
        let result = try FitNotesImporter.parse(text, options: ImportOptions(timeZone: saoPaulo))
        #expect(result.rowErrors.isEmpty)
        let start = try #require(result.workouts.first?.startedAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = saoPaulo
        #expect(calendar.dateComponents([.year, .month, .day, .hour], from: start)
                    == DateComponents(year: 2018, month: 11, day: 4, hour: 12))
    }
}
