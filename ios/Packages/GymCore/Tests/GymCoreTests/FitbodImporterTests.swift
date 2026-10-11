import Foundation
import Testing
@testable import GymCore

@Suite struct FitbodImporterTests {
    static let header = "Date,Exercise,Reps,Weight(kg),Duration(s),Distance(m),Incline,Resistance,isWarmup,Note,multiplier"
    static let sample = """
    \(header)
    2026-09-19 18:02:11 +0000,Barbell Bench Press, 10,58.96707822663317,0.0,0.0,0.0,0.0,false,, 1.0
    2026-09-19 18:02:11 +0000,Barbell Bench Press, 10,58.96707822663317,0.0,0.0,0.0,0.0,false,, 1.0
    2026-09-19 18:02:11 +0000,Hammer Curls, 10,9.071858188712795,0.0,0.0,0.0,0.0,false,, 2.0
    2026-09-22 22:38:41 +0000,Lat Pulldown, 10,31.75150366049478,0.0,0.0,0.0,0.0,true,, 1.0
    2026-09-22 22:38:41 +0000,Lat Pulldown, 10,54.431084445645396,0.0,0.0,0.0,0.0,false,felt strong, 1.0
    2026-09-22 22:38:41 +0000,Walking, 0,0.0,1800.0,2400.0,0.0,0.0,false,, 1.0
    not-a-date,Lat Pulldown, 10,54.4,0.0,0.0,0.0,0.0,false,, 1.0
    2026-09-22 22:38:41 +0000,Lat Pulldown, ten,54.4,0.0,0.0,0.0,0.0,false,, 1.0
    2026-09-22 22:38:41 +0000,Lat Pulldown
    """

    @Test func groupsRowsIntoWorkoutsByTimestamp() throws {
        let result = try FitbodImporter.parse(Self.sample)
        #expect(result.workouts.count == 2)
        #expect(result.workouts.map(\.entries.count) == [2, 2])
        #expect(result.workouts[0].entries[0].exerciseName == "Barbell Bench Press")
        #expect(result.workouts[0].entries[0].sets.count == 2)
        #expect(result.rowCount == 9)
    }

    @Test func mapsFields() throws {
        let result = try FitbodImporter.parse(Self.sample)
        let hammer = result.workouts[0].entries[1].sets[0]
        #expect(hammer.reps == 10)
        #expect(abs(hammer.weightKg - 9.0719) < 0.001)
        #expect(hammer.multiplier == 2)
        let pulldown = result.workouts[1].entries[0].sets
        #expect(pulldown[0].warmup == true)
        #expect(pulldown[1].note == "felt strong")
        let walking = result.workouts[1].entries[1].sets[0]
        #expect(walking.durationSec == 1_800)
        #expect(walking.distanceM == 2_400)
        #expect(result.warmupSetCount == 1)
    }

    @Test func reportsBadRowsWithLineNumbers() throws {
        let result = try FitbodImporter.parse(Self.sample)
        #expect(result.rowErrors.map(\.line) == [8, 9, 10])
    }

    @Test func idsAreDeterministic() throws {
        let a = try FitbodImporter.parse(Self.sample)
        let b = try FitbodImporter.parse(Self.sample)
        #expect(a.workouts.map(\.id) == b.workouts.map(\.id))
        #expect(a.workouts[0].id != a.workouts[1].id)
    }

    @Test func parsesTimestamp() throws {
        let result = try FitbodImporter.parse(Self.sample)
        #expect(result.workouts[1].startedAt == Date(timeIntervalSince1970: 1_790_116_721))
    }

    @Test func rejectsUnknownHeader() {
        #expect(throws: FitbodImportError.unrecognizedHeader(["Date", "Lift"])) {
            try FitbodImporter.parse("Date,Lift\n1,2\n")
        }
    }

    @Test func rejectsEmptyFile() {
        #expect(throws: FitbodImportError.emptyFile) { try FitbodImporter.parse("") }
    }

    @Test func parsesHeaderWithLeadingBOM() throws {
        let result = try FitbodImporter.parse("\u{FEFF}\(Self.sample)")
        #expect(result.workouts.count == 2)
    }

    @Test func fractionalRepsProduceRowError() throws {
        let text = """
        \(Self.header)
        2026-09-22 22:38:41 +0000,Lat Pulldown, 8.5,54.4,0.0,0.0,0.0,0.0,false,, 1.0
        """
        let result = try FitbodImporter.parse(text)
        #expect(result.workouts.isEmpty)
        #expect(result.rowErrors.count == 1)
        #expect(result.rowErrors[0].message == "Reps must be a whole number")
    }

    @Test func hugeRepsValueProducesRowError() throws {
        let text = """
        \(Self.header)
        2026-09-22 22:38:41 +0000,Lat Pulldown, 1e100,54.4,0.0,0.0,0.0,0.0,false,, 1.0
        """
        let result = try FitbodImporter.parse(text)
        #expect(result.workouts.isEmpty)
        #expect(result.rowErrors.count == 1)
        #expect(result.rowErrors[0].message == "Value out of range")
    }

    @Test func infiniteWeightProducesRowError() throws {
        let text = """
        \(Self.header)
        2026-09-22 22:38:41 +0000,Lat Pulldown, 10,inf,0.0,0.0,0.0,0.0,false,, 1.0
        """
        let result = try FitbodImporter.parse(text)
        #expect(result.workouts.isEmpty)
        #expect(result.rowErrors.count == 1)
        #expect(result.rowErrors[0].message == "Value out of range")
    }

    @Test func nanWeightProducesRowError() throws {
        let text = """
        \(Self.header)
        2026-09-22 22:38:41 +0000,Lat Pulldown, 10,nan,0.0,0.0,0.0,0.0,false,, 1.0
        """
        let result = try FitbodImporter.parse(text)
        #expect(result.workouts.isEmpty)
        #expect(result.rowErrors.count == 1)
        #expect(result.rowErrors[0].message == "Value out of range")
    }

    @Test func hugeDurationProducesRowError() throws {
        let text = """
        \(Self.header)
        2026-09-22 22:38:41 +0000,Lat Pulldown, 10,54.4,1e12,0.0,0.0,0.0,false,, 1.0
        """
        let result = try FitbodImporter.parse(text)
        #expect(result.workouts.isEmpty)
        #expect(result.rowErrors.count == 1)
        #expect(result.rowErrors[0].message == "Value out of range")
    }

    @Test func hugeDistanceProducesRowError() throws {
        let text = """
        \(Self.header)
        2026-09-22 22:38:41 +0000,Walking, 0,0.0,1800.0,1e9,0.0,0.0,false,, 1.0
        """
        let result = try FitbodImporter.parse(text)
        #expect(result.workouts.isEmpty)
        #expect(result.rowErrors.count == 1)
        #expect(result.rowErrors[0].message == "Value out of range")
    }

    @Test func badRowAfterBlankLineReportsTrueSourceLine() throws {
        // Blank lines were previously dropped before line numbers were assigned, so a bad row
        // after one reported the wrong (shifted-down) line.
        let text = "\(Self.header)\n\nnot-a-date,Lat Pulldown, 10,54.4,0.0,0.0,0.0,0.0,false,, 1.0\n"
        let result = try FitbodImporter.parse(text)
        #expect(result.rowErrors.map(\.line) == [3])
    }

    @Test func badRowAfterQuotedMultilineNoteReportsTrueSourceLine() throws {
        let text = """
        \(Self.header)
        2026-09-22 22:38:41 +0000,Lat Pulldown, 10,54.4,0.0,0.0,0.0,0.0,false,"line one
        line two", 1.0
        not-a-date,Lat Pulldown, 10,54.4,0.0,0.0,0.0,0.0,false,, 1.0
        """
        let result = try FitbodImporter.parse(text)
        #expect(result.rowErrors.map(\.line) == [4])
    }

    @Test func hugeMultiplierProducesRowError() throws {
        let text = """
        \(Self.header)
        2026-09-22 22:38:41 +0000,Lat Pulldown, 10,54.4,0.0,0.0,0.0,0.0,false,, 1e5
        """
        let result = try FitbodImporter.parse(text)
        #expect(result.workouts.isEmpty)
        #expect(result.rowErrors.count == 1)
        #expect(result.rowErrors[0].message == "Value out of range")
    }
}
