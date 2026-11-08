import Foundation
import Testing
@testable import GymCore

/// A workout from an export comes back as pieces the server stores (server/src/sync/workouts.ts): at most 50
/// exercises a piece and 50 sets an exercise, every set kept, in order.
@Suite struct ImportSplitTests {
    private let start = Date(timeIntervalSince1970: 1_767_636_000) // 2026-01-05 18:00 UTC
    private let utc = ImportOptions(weightUnit: .kg, timeZone: TimeZone(identifier: "UTC")!)

    private func entry(_ name: String, sets: Int) -> ImportedEntry {
        ImportedEntry(exerciseName: name, sets: (0..<sets).map { ImportedSet(weightKg: 60, reps: $0 + 1) })
    }

    private func workout(_ entries: [ImportedEntry]) -> ImportedWorkout {
        ImportedWorkout(id: UUID(), startedAt: start, entries: entries, name: "Big day", endedAt: start + 3_600)
    }

    @Test func aWorkoutThatFitsIsLeftAsItIs() {
        let fits = workout([entry("Bench", sets: 50)] + (1..<50).map { entry("Ex \($0)", sets: 1) })
        #expect(ImportSplit.pieces(fits) == [fits])
        let empty = workout([])
        #expect(ImportSplit.pieces(empty) == [empty])
    }

    @Test func anExerciseWithMoreThan50SetsGoesOnAsAnotherEntry() {
        let source = workout([entry("Bench", sets: 120), entry("Row", sets: 3)])
        let pieces = ImportSplit.pieces(source)
        #expect(pieces.count == 1)
        #expect(pieces[0].id == source.id && pieces[0].part == 1 && pieces[0].splitFrom == nil)
        #expect(pieces[0].entries.map(\.exerciseName) == ["Bench", "Bench", "Bench", "Row"])
        #expect(pieces[0].entries.map(\.sets.count) == [50, 50, 20, 3])
        #expect(pieces[0].entries.flatMap(\.sets) == source.entries.flatMap(\.sets))
    }

    @Test func moreThan50ExercisesGoOnInTheNextWorkoutsOneSecondApart() {
        let source = workout((0..<120).map { entry("Ex \($0)", sets: 2) })
        let pieces = ImportSplit.pieces(source)
        #expect(pieces.map(\.entries.count) == [50, 50, 20])
        #expect(pieces.map(\.part) == [1, 2, 3])
        #expect(pieces.map(\.id)[0] == source.id)
        #expect(pieces.dropFirst().allSatisfy { $0.splitFrom == source.id && $0.id != source.id })
        #expect(pieces.map(\.startedAt) == [start, start + 1, start + 2])
        #expect(pieces.allSatisfy { $0.name == "Big day" && $0.endedAt == source.endedAt })
        #expect(pieces.flatMap(\.entries) == source.entries)
        #expect(ImportSplit.pieces(source).map(\.id) == pieces.map(\.id)) // the same ids on every import
    }

    @Test func aLongExerciseMayContinueInTheNextWorkout() {
        let source = workout((0..<49).map { entry("Ex \($0)", sets: 1) } + [entry("Squat", sets: 70)])
        let pieces = ImportSplit.pieces(source)
        #expect(pieces.map(\.entries.count) == [50, 1])
        #expect(pieces[0].entries.last?.exerciseName == "Squat" && pieces[0].entries.last?.sets.count == 50)
        #expect(pieces[1].entries.map(\.exerciseName) == ["Squat"] && pieces[1].entries[0].sets.count == 20)
    }

    @Test func piecesAfterTheFirstAreNumberedWithinTheNameLimit() {
        #expect(ImportSplit.name("Push", part: 1) == "Push")
        #expect(ImportSplit.name("Push", part: 2) == "Push (2)")
        let long = String(repeating: "x", count: DomainLimits.workoutNameMax)
        #expect(ImportSplit.name(long, part: 1) == long)
        #expect(ImportSplit.name(long, part: 12).count == DomainLimits.workoutNameMax)
        #expect(ImportSplit.name(long, part: 12).hasSuffix(" (12)"))
    }

    /// One export per importer: a workout of 51 exercises, the first with 120 sets.
    private static let exports: [(ImportSource, String)] = [
        (.fitNotes, "Date,Exercise,Category,Weight (kg),Weight (lbs),Reps,Distance,Distance Unit,Time,Notes,Kind\n"
            + rows { "2026-01-05,\($0),Chest,60.0,,\($1 + 1),,,,,wr" }),
        (.strong, "Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,Notes,Workout Notes,RPE\n"
            + rows { "2026-01-05 18:00:00,Big day,1h 5m,\($0),\($1 + 1),60,\($1 + 1),0,0,,," }),
        (.hevy, "title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,"
            + "set_type,weight_kg,reps,distance_km,duration_seconds,rpe\n"
            + rows { #""Big day","5 Jan 2026, 18:00","5 Jan 2026, 19:10","","\#($0)",,"",\#($1),"normal",60,\#($1 + 1),,,"# }),
        (.fitbod, "Date,Exercise,Reps,Weight(kg),Duration(s),Distance(m),Incline,Resistance,isWarmup,Note,multiplier\n"
            + rows { "2026-01-05 18:00:00 +0000,\($0), \($1 + 1),60.0,0.0,0.0,0.0,0.0,false,, 1.0" }),
    ]

    /// "Ex 0" with 120 sets, then "Ex 1" … "Ex 50" with one set each: (exercise, set index) per row.
    private static func rows(_ row: (String, Int) -> String) -> String {
        ((0..<120).map { row("Ex 0", $0) } + (1...50).map { row("Ex \($0)", 0) }).joined(separator: "\n")
    }

    @Test(arguments: exports.map(\.0))
    func everyImporterSplitsAnOversizedWorkout(source: ImportSource) throws {
        let text = try #require(Self.exports.first { $0.0 == source }?.1)
        let result = try WorkoutImporters.parse(text, source: source, options: utc)
        #expect(result.rowErrors.isEmpty)
        #expect(result.workouts.map(\.part) == [1, 2])
        #expect(result.workouts.map(\.entries.count) == [50, 3])
        #expect(result.workouts.allSatisfy { $0.entries.allSatisfy { $0.sets.count <= DomainLimits.entrySetsMax } })
        let names = result.workouts.flatMap(\.entries).map(\.exerciseName)
        #expect(names == ["Ex 0", "Ex 0", "Ex 0"] + (1...50).map { "Ex \($0)" })
        #expect(result.workouts.flatMap(\.entries).flatMap(\.sets).count == 170)
        #expect(result.workouts[1].splitFrom == result.workouts[0].id)
        #expect(result.workouts[1].startedAt == result.workouts[0].startedAt + 1)
        #expect(try WorkoutImporters.parse(text, source: source, options: utc).workouts.map(\.id)
            == result.workouts.map(\.id))
    }
}
