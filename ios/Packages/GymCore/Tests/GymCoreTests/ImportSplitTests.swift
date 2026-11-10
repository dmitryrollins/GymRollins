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

    private func workout(_ entries: [ImportedEntry], lasting duration: TimeInterval? = 3_600) -> ImportedWorkout {
        ImportedWorkout(id: UUID(), startedAt: start, entries: entries, name: "Big day",
                        endedAt: duration.map { start + $0 })
    }

    /// The pieces follow each other: piece 1 starts at the source's start, each starts where the one before ended,
    /// the last ends at the source's end, and each lasts at least a second.
    private func expectConsecutive(_ pieces: [ImportedWorkout], from source: ImportedWorkout,
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(pieces.first?.startedAt == source.startedAt, sourceLocation: sourceLocation)
        #expect(pieces.last?.endedAt == source.endedAt, sourceLocation: sourceLocation)
        for (piece, next) in zip(pieces, pieces.dropFirst()) {
            #expect(piece.endedAt == next.startedAt, sourceLocation: sourceLocation)
        }
        for piece in pieces {
            #expect(piece.endedAt.map { $0.timeIntervalSince(piece.startedAt) >= 1 } == true,
                    sourceLocation: sourceLocation)
        }
        let total = pieces.compactMap { p in p.endedAt.map { $0.timeIntervalSince(p.startedAt) } }.reduce(0, +)
        #expect(abs(total - (source.endedAt ?? source.startedAt).timeIntervalSince(source.startedAt)) < 0.001,
                sourceLocation: sourceLocation)
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

    @Test func moreThan50ExercisesGoOnInTheNextWorkoutsOneAfterAnother() {
        let source = workout((0..<120).map { entry("Ex \($0)", sets: 2) })
        let pieces = ImportSplit.pieces(source)
        #expect(pieces.map(\.entries.count) == [50, 50, 20])
        #expect(pieces.map(\.part) == [1, 2, 3])
        #expect(pieces.map(\.id)[0] == source.id)
        #expect(pieces.dropFirst().allSatisfy { $0.splitFrom == source.id && $0.id != source.id })
        // The hour shared by sets: 100, 100 and 40 of 240.
        #expect(pieces.map(\.startedAt) == [start, start + 1_500, start + 3_000])
        #expect(pieces.map(\.endedAt) == [start + 1_500, start + 3_000, start + 3_600])
        expectConsecutive(pieces, from: source)
        #expect(pieces.allSatisfy { $0.name == "Big day" && $0.note == source.note })
        #expect(pieces.flatMap(\.entries) == source.entries)
        #expect(ImportSplit.pieces(source).map(\.id) == pieces.map(\.id)) // the same ids on every import
    }

    /// Each piece's share of the session follows its sets, so time and calories aren't counted twice.
    @Test func thePiecesShareTheSessionByTheirSets() {
        let source = workout([entry("Bench", sets: 120)] + (1...50).map { entry("Ex \($0)", sets: 1) })
        let pieces = ImportSplit.pieces(source) // 120 + 47 sets, then 3
        #expect(pieces.map(\.entries.count) == [50, 3])
        expectConsecutive(pieces, from: source)
        #expect(pieces[1].startedAt == start + 3_600 * 167 / 170)

        let empty = workout((0..<120).map { entry("Ex \($0)", sets: 0) }) // no sets: equal shares
        #expect(ImportSplit.pieces(empty).map(\.startedAt) == [start, start + 1_200, start + 2_400])
        expectConsecutive(ImportSplit.pieces(empty), from: empty)

        let short = workout((0..<101).map { entry("Ex \($0)", sets: $0 < 100 ? 3 : 1) }, lasting: 10)
        let shortPieces = ImportSplit.pieces(short) // 150, 150 and 1 sets in 10 seconds: the last gets a second
        expectConsecutive(shortPieces, from: short)
        #expect(shortPieces.last?.startedAt == start + 9)
    }

    /// Without a usable end time there is no session to share: piece k starts k - 1 seconds after the source,
    /// with the source's end (or none), as before.
    @Test func withoutAnEndTimeThePiecesStartASecondApart() {
        for duration in [nil, 0, 2] as [TimeInterval?] {
            let source = workout((0..<120).map { entry("Ex \($0)", sets: 2) }, lasting: duration)
            let pieces = ImportSplit.pieces(source)
            #expect(pieces.map(\.startedAt) == [start, start + 1, start + 2])
            #expect(pieces.allSatisfy { $0.endedAt == source.endedAt })
        }
    }

    @Test(arguments: [(50, [50]), (51, [50, 1]), (100, [50, 50]), (101, [50, 50, 1])])
    func exercisesAtTheBoundaries(count: Int, pieces sizes: [Int]) {
        let source = workout((0..<count).map { entry("Ex \($0)", sets: 1) })
        let pieces = ImportSplit.pieces(source)
        #expect(pieces.map(\.entries.count) == sizes)
        #expect(pieces.map(\.part) == Array(1...sizes.count))
        #expect(pieces.flatMap(\.entries) == source.entries)
        if sizes.count == 1 { #expect(pieces == [source]) } else { expectConsecutive(pieces, from: source) }
    }

    @Test(arguments: [(50, [50]), (51, [50, 1]), (100, [50, 50]), (101, [50, 50, 1])])
    func setsAtTheBoundaries(count: Int, runs: [Int]) {
        let source = workout([entry("Bench", sets: count)])
        let pieces = ImportSplit.pieces(source)
        #expect(pieces.count == 1)
        #expect(pieces[0].entries.map(\.sets.count) == runs)
        #expect(pieces[0].entries.allSatisfy { $0.exerciseName == "Bench" })
        #expect(pieces[0].entries.flatMap(\.sets) == source.entries[0].sets)
        #expect(pieces[0].startedAt == source.startedAt && pieces[0].endedAt == source.endedAt)
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

    /// One export per importer: a workout of "Ex 0" with 120 sets, then `more` exercises of one set each.
    private static func export(_ source: ImportSource, more: Int) -> String {
        switch source {
        case .fitNotes:
            "Date,Exercise,Category,Weight (kg),Weight (lbs),Reps,Distance,Distance Unit,Time,Notes,Kind\n"
                + rows(more) { "2026-01-05,\($0),Chest,60.0,,\($1 + 1),,,,,wr" }
        case .strong:
            "Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,Notes,Workout Notes,RPE\n"
                + rows(more) { "2026-01-05 18:00:00,Big day,1h 5m,\($0),\($1 + 1),60,\($1 + 1),0,0,,," }
        case .hevy:
            "title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,"
                + "set_type,weight_kg,reps,distance_km,duration_seconds,rpe\n"
                + rows(more) {
                    #""Big day","5 Jan 2026, 18:00","5 Jan 2026, 19:10","","\#($0)",,"",\#($1),"normal",60,\#($1 + 1),,,"#
                }
        case .fitbod:
            "Date,Exercise,Reps,Weight(kg),Duration(s),Distance(m),Incline,Resistance,isWarmup,Note,multiplier\n"
                + rows(more) { "2026-01-05 18:00:00 +0000,\($0), \($1 + 1),60.0,0.0,0.0,0.0,0.0,false,, 1.0" }
        }
    }

    /// "Ex 0" with 120 sets, then "Ex 1" … "Ex <more>" with one set each: (exercise, set index) per row.
    private static func rows(_ more: Int, _ row: (String, Int) -> String) -> String {
        ((0..<120).map { row("Ex 0", $0) } + (1...more).map { row("Ex \($0)", 0) }).joined(separator: "\n")
    }

    /// The pieces through an importer: in order, one after another (Strong and Hevy write an end time, Fitbod and
    /// FitNotes don't).
    private func expectInOrder(_ pieces: [ImportedWorkout], sourceLocation: SourceLocation = #_sourceLocation) {
        for (piece, next) in zip(pieces, pieces.dropFirst()) {
            #expect(next.splitFrom == pieces[0].id && next.id != piece.id, sourceLocation: sourceLocation)
            #expect(next.startedAt == (piece.endedAt ?? piece.startedAt + 1), sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: ImportSource.allCases)
    func everyImporterSplitsAnOversizedWorkout(source: ImportSource) throws {
        let text = Self.export(source, more: 50)
        let result = try WorkoutImporters.parse(text, source: source, options: utc)
        #expect(result.rowErrors.isEmpty)
        #expect(result.workouts.map(\.part) == [1, 2])
        #expect(result.workouts.map(\.entries.count) == [50, 3])
        #expect(result.workouts.allSatisfy { $0.entries.allSatisfy { $0.sets.count <= DomainLimits.entrySetsMax } })
        let names = result.workouts.flatMap(\.entries).map(\.exerciseName)
        #expect(names == ["Ex 0", "Ex 0", "Ex 0"] + (1...50).map { "Ex \($0)" })
        #expect(result.workouts.flatMap(\.entries).flatMap(\.sets).count == 170)
        #expect(result.workouts[1].splitFrom == result.workouts[0].id)
        expectInOrder(result.workouts)
        #expect(try WorkoutImporters.parse(text, source: source, options: utc).workouts.map(\.id)
            == result.workouts.map(\.id))
    }

    @Test(arguments: ImportSource.allCases)
    func everyImporterNumbersAThirdPiece(source: ImportSource) throws {
        let text = Self.export(source, more: 100) // 3 runs of "Ex 0" and 100 more: 50, 50 and 3 entries
        let result = try WorkoutImporters.parse(text, source: source, options: utc)
        #expect(result.rowErrors.isEmpty)
        #expect(result.workouts.map(\.part) == [1, 2, 3])
        #expect(result.workouts.map(\.entries.count) == [50, 50, 3])
        #expect(result.workouts.flatMap(\.entries).flatMap(\.sets).count == 220)
        #expect(result.workouts.flatMap(\.entries).map(\.exerciseName).suffix(3) == ["Ex 98", "Ex 99", "Ex 100"])
        expectInOrder(result.workouts)
        #expect(Set(result.workouts.map(\.id)).count == 3)
        #expect(try WorkoutImporters.parse(text, source: source, options: utc).workouts.map(\.id)
            == result.workouts.map(\.id))
    }
}
