import Foundation
import Testing
@testable import GymCore

@Suite struct HevyImporterTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let kgHeader = "title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,"
        + "set_type,weight_kg,reps,distance_km,duration_seconds,rpe"
    static let lbHeader = "title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,"
        + "set_type,weight_lbs,reps,distance_miles,duration_seconds,rpe"
    static let sample = """
    \(kgHeader)
    "Upper, A","5 Jan 2026, 18:00","5 Jan 2026, 19:10","Chest focus","Bench Press (Barbell)",,"Pause at bottom",0,"warmup",40,10,,,
    "Upper, A","5 Jan 2026, 18:00","5 Jan 2026, 19:10","Chest focus","Bench Press (Barbell)",,"Pause at bottom",1,"normal",80,8,,,8
    "Upper, A","5 Jan 2026, 18:00","5 Jan 2026, 19:10","Chest focus","Bench Press (Barbell)",,"Pause at bottom",2,"drop_set",60,10,,,
    "Upper, A","5 Jan 2026, 18:00","5 Jan 2026, 19:10","Chest focus","Bicep Curl (Dumbbell)",1,"",0,"normal",14,10,,,
    "Upper, A","5 Jan 2026, 18:00","5 Jan 2026, 19:10","Chest focus","Triceps Pushdown",1,"",0,"failure",30,12,,,9.5
    "Legs","7 Jan 2026, 07:30","7 Jan 2026, 08:25","","Plank",,"",0,"normal",,,,60,
    "Legs","7 Jan 2026, 07:30","7 Jan 2026, 08:25","","Running",,"",0,"normal",,,2.5,900,
    "Legs","7 Jan 2026, 07:30","7 Jan 2026, 08:25","","Squat (Barbell)",,"",0,"normal",100,x,,,
    "Legs","7 Jan 2026, 07:30","7 Jan 2026, 08:25","","Squat (Barbell)",,"",1,"dropset",100,5,,,
    "Legs","sometime","7 Jan 2026, 08:25","","Squat (Barbell)",,"",2,"normal",100,5,,,
    "Pull","09 Jan 2026, 12:00","9 Jan 2026, 12:55","Back day
    felt strong","Pull Up",,"",0,"garbage",,10,,,
    "Pull","09 Jan 2026, 12:00","9 Jan 2026, 12:55","Back day
    felt strong","Pull Up",,"",1,"normal",,,,,
    """

    private func parse(_ text: String = sample) throws -> WorkoutImportResult {
        try HevyImporter.parse(text, options: ImportOptions(weightUnit: .lb, timeZone: Self.utc))
    }

    @Test func recognizesBothUnitHeaders() {
        #expect(HevyImporter.recognizes(header: Self.kgHeader.components(separatedBy: ",")))
        #expect(HevyImporter.recognizes(header: Self.lbHeader.components(separatedBy: ",")))
        #expect(!HevyImporter.needsWeightUnit(header: Self.kgHeader.components(separatedBy: ",")))
        #expect(!HevyImporter.recognizes(header: FitbodImporter.expectedHeader))
        #expect(WorkoutImporters.detect(Self.sample) == .hevy)
    }

    @Test func groupsWorkoutsWithTitlesTimesAndDescription() throws {
        let result = try parse()
        #expect(result.source == .hevy)
        #expect(result.workouts.map(\.name) == ["Upper, A", "Legs", "Pull"])
        let upper = result.workouts[0]
        #expect(upper.startedAt == Date(timeIntervalSince1970: 1_767_636_000)) // 2026-01-05 18:00 UTC
        #expect(upper.endedAt == upper.startedAt.addingTimeInterval(70 * 60))
        #expect(upper.note == "Chest focus")
        #expect(result.workouts[1].note == nil)
        #expect(result.workouts[2].note == "Back day\nfelt strong")
    }

    @Test func setTypesUnitsRpeAndNotes() throws {
        let upper = try parse().workouts[0]
        let bench = upper.entries[0].sets
        #expect(bench.map(\.warmup) == [true, false, false])
        #expect(bench.map(\.weightKg) == [40, 80, 60]) // kg column: the lb option is ignored
        #expect(bench[1].rpe == 8)
        #expect(bench[0].note == "Pause at bottom")
        #expect(upper.entries[2].sets[0].rpe == 9.5)
        #expect(try parse().warmupSetCount == 1)
    }

    @Test func supersetIdsBecomeEntryGroups() throws {
        let upper = try parse().workouts[0]
        #expect(upper.entries.map(\.supersetGroup) == [nil, "1", "1"])
    }

    @Test func timedDistanceAndBodyweightSets() throws {
        let result = try parse()
        let legs = result.workouts[1].entries
        #expect(legs[0].sets[0].durationSec == 60 && legs[0].sets[0].reps == 0)
        #expect(legs[1].sets[0].distanceM == 2_500 && legs[1].sets[0].durationSec == 900)
        let pullUp = result.workouts[2].entries[0].sets
        #expect(pullUp.count == 1)
        #expect(pullUp[0].weightKg == 0 && pullUp[0].reps == 10 && !pullUp[0].warmup) // unknown set_type → normal
    }

    @Test func malformedRowsAreReportedWithSourceLines() throws {
        let result = try parse()
        #expect(result.rowErrors.map(\.line) == [9, 11])
        #expect(result.rowErrors[0].message == "Unreadable number in row")
        #expect(result.rowErrors[1].message == "Unreadable date 'sometime'")
        #expect(result.ignoredRowCount == 1) // the empty Pull Up set
        #expect(result.workouts[1].entries.first { $0.exerciseName == "Squat (Barbell)" }?.sets.count == 1)
    }

    @Test func poundsAndMilesColumnsConvert() throws {
        let text = """
        \(Self.lbHeader)
        "Push","5 Jan 2026, 18:00","5 Jan 2026, 19:00","","Bench Press (Barbell)",,"",0,"normal",135,8,,,
        "Push","5 Jan 2026, 18:00","5 Jan 2026, 19:00","","Running",,"",0,"normal",,,1,540,
        """
        let workout = try #require(try parse(text).workouts.first)
        #expect(abs(workout.entries[0].sets[0].weightKg - 61.235) < 0.001)
        #expect(abs((workout.entries[1].sets[0].distanceM ?? 0) - 1_609.344) < 0.001)
    }

    @Test func twelveHourDateVariantParses() throws {
        let text = """
        \(Self.kgHeader)
        "Push","Mar 28, 2025, 5:29 PM","Mar 28, 2025, 6:52 PM","","Bench Press (Barbell)",,"",0,"normal",60,8,,,
        """
        let workout = try #require(try parse(text).workouts.first)
        #expect(workout.startedAt == Date(timeIntervalSince1970: 1_743_182_940)) // 2025-03-28 17:29 UTC
        #expect(workout.endedAt == workout.startedAt.addingTimeInterval(83 * 60))
    }

    @Test func idsAreDeterministic() throws {
        #expect(try parse().workouts.map(\.id) == parse().workouts.map(\.id))
        #expect(Set(try parse().workouts.map(\.id)).count == 3)
    }

    @Test func endBeforeStartIsDropped() throws {
        let text = """
        \(Self.kgHeader)
        "Push","5 Jan 2026, 18:00","5 Jan 2026, 17:00","","Bench Press (Barbell)",,"",0,"normal",60,8,,,
        """
        #expect(try parse(text).workouts.first?.endedAt == nil)
    }

    @Test func sameExerciseInTwoSupersetsStaysTwoEntries() throws {
        let row = { (exercise: String, superset: String, weight: Int) in
            "\"Push\",\"5 Jan 2026, 18:00\",\"5 Jan 2026, 19:00\",\"\",\"\(exercise)\",\(superset),\"\",0,\"normal\",\(weight),10,,,"
        }
        let text = [Self.kgHeader, row("Lateral Raise (Dumbbell)", "1", 10), row("Bench Press (Barbell)", "1", 60),
                    row("Lateral Raise (Dumbbell)", "2", 8), row("Face Pull", "2", 20)].joined(separator: "\n")
        let entries = try #require(try parse(text).workouts.first?.entries)
        #expect(entries.map(\.exerciseName) == ["Lateral Raise (Dumbbell)", "Bench Press (Barbell)",
                                               "Lateral Raise (Dumbbell)", "Face Pull"])
        #expect(entries.map(\.supersetGroup) == ["1", "1", "2", "2"])
        #expect(entries.map { $0.sets.map(\.weightKg) } == [[10], [60], [8], [20]])
    }
}
