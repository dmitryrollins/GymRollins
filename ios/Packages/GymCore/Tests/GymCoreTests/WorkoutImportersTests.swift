import Foundation
import Testing
@testable import GymCore

@Suite struct WorkoutImportersTests {
    static let fitbod = """
    \(FitbodImporterTests.header)
    2026-09-19 18:02:11 +0000,Barbell Bench Press, 10,58.9,0.0,0.0,0.0,0.0,false,, 1.0
    """

    @Test func everySourceHasOneImporter() {
        #expect(WorkoutImporters.all.map { $0.source } == ImportSource.allCases)
        for source in ImportSource.allCases {
            #expect(WorkoutImporters.importer(for: source).source == source)
        }
    }

    @Test func autoDetectPicksTheRightImporter() throws {
        #expect(try WorkoutImporters.parse(Self.fitbod, source: nil).source == .fitbod)
        #expect(try WorkoutImporters.parse(StrongImporterTests.sample, source: nil).source == .strong)
        #expect(try WorkoutImporters.parse(HevyImporterTests.sample, source: nil).source == .hevy)
        #expect(try WorkoutImporters.parse(FitNotesImporterTests.sample, source: nil).source == .fitNotes)
    }

    @Test func explicitSourceMatchingTheFileParses() throws {
        #expect(try WorkoutImporters.parse(HevyImporterTests.sample, source: .hevy).workouts.count == 3)
    }

    @Test func pickingTheWrongAppNamesTheDetectedOne() {
        #expect(throws: WorkoutImportError.sourceMismatch(selected: .strong, detected: .hevy)) {
            try WorkoutImporters.parse(HevyImporterTests.sample, source: .strong)
        }
    }

    @Test func unknownHeaderAndEmptyFile() {
        #expect(throws: WorkoutImportError.unrecognizedHeader(["Date", "Lift"])) {
            try WorkoutImporters.parse("Date,Lift\n1,2\n", source: nil)
        }
        #expect(throws: WorkoutImportError.unrecognizedHeader(["Date", "Lift"])) {
            try WorkoutImporters.parse("Date,Lift\n1,2\n", source: .strong)
        }
        #expect(throws: WorkoutImportError.emptyFile) { try WorkoutImporters.parse("", source: nil) }
        #expect(throws: WorkoutImportError.emptyFile) { try WorkoutImporters.parse("\n\n", source: .hevy) }
        #expect(WorkoutImporters.detect("") == nil)
    }

    @Test func headerDetectionSkipsBOMAndLeadingBlankLines() {
        #expect(WorkoutImporters.header(of: "\u{FEFF}\n\nDate;Exercise\nx") == ["Date", "Exercise"])
    }

    @Test func numbersAcceptDecimalCommas() {
        #expect(ImportNumber.parse("62,5") == .number(62.5))
        #expect(ImportNumber.parse(" 62.5 ") == .number(62.5))
        #expect(ImportNumber.parse("") == .empty)
        #expect(ImportNumber.parse("1,000,5") == .invalid)
        #expect(ImportNumber.parse("abc") == .invalid)
    }

    @Test func distanceUnitAbbreviations() {
        #expect(DistanceUnit(abbreviation: "KM") == .kilometers)
        #expect(DistanceUnit(abbreviation: "mi") == .miles)
        #expect(DistanceUnit(abbreviation: "yd")?.toMeters(100) == 91.44)
        #expect(DistanceUnit(abbreviation: "cm")?.toMeters(250) == 2.5)
        #expect(DistanceUnit(abbreviation: "furlong") == nil)
    }

    @Test func semicolonExportAfterBlankLinesParses() throws {
        let text = "\n\nDate;Workout Name;Exercise Name;Set Order;Weight;Weight Unit;Reps\n"
            + "2026-02-02 17:45:00;Push;Bench Press (Barbell);1;60;kg;8\n"
        let result = try WorkoutImporters.parse(text, source: nil)
        #expect(result.source == .strong)
        #expect(result.workouts.first?.entries.first?.sets.first?.weightKg == 60)
        #expect(result.workouts.count == 1 && result.rowErrors.isEmpty)
    }

    @Test(arguments: [
        (ImportSource.strong, "Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,RPE\n"
            + "2026-01-05 18:00:00,Push,1h,Bench Press (Barbell),1,100\n"),
        (.hevy, HevyImporterTests.kgHeader
            + "\n\"Push\",\"5 Jan 2026, 18:00\",\"5 Jan 2026, 19:00\",\"\",\"Bench\",,\"\",0,\"normal\",60\n"),
        (.fitNotes, "Date,Exercise,Category,Weight (kg),Weight (lbs),Reps,Distance\n2026-01-05,Deadlift,Back,100\n"),
        // Cardio rows cut off after the (blank) reps cell: distance and duration are missing, not empty.
        (.hevy, HevyImporterTests.kgHeader
            + "\n\"Run\",\"5 Jan 2026, 18:00\",\"5 Jan 2026, 19:00\",\"\",\"Running\",,\"\",0,\"normal\",,\n"),
        (.strong, StrongImporterTests.header + "\n2026-01-05 18:00:00,Run,1h,Running,1,0,0\n"),
        (.fitNotes, FitNotesImporterTests.header + "\n2026-01-05,Running,Cardio,,,\n")
    ])
    func truncatedRowsAreErrorsNotSilentlyDropped(_ source: ImportSource, text: String) throws {
        let result = try WorkoutImporters.parse(text, source: source)
        #expect(result.workouts.isEmpty)
        #expect(result.ignoredRowCount == 0)
        #expect(result.rowErrors.map(\.line) == [2])
        #expect(result.rowErrors.first?.message.hasPrefix("Row is missing columns") == true)
    }
}
