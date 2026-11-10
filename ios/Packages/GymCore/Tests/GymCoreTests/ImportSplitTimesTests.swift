import Foundation
import Testing
@testable import GymCore

/// The pieces' times over start and end combinations (plan 31, decision 10). With a span of at least a second a piece,
/// the pieces share it out in order, so the session's time is counted once. Without one (no end time, or too short),
/// they start a second apart and keep the source's end: there is no span to share, so the pieces can't both last a
/// second each and stay inside it, and the app estimates such a piece's end itself (`ImportService.endedAt`).
@Suite struct ImportSplitTimesTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let start: Date
        /// Seconds from the source's start to its end; nil when the export has no end time.
        let span: TimeInterval?
        /// The sets in each piece the split makes: 50 exercises a piece, `lastEntries` in the last.
        let sets: [Int]
        var lastEntries = DomainLimits.workoutEntriesMax
        /// True when the span is at least a second a piece, so the pieces share it.
        let shares: Bool
    }

    private static let start = Date(timeIntervalSince1970: 1_767_636_000) // 2026-01-05 18:00 UTC

    static let cases: [Case] = [
        Case(testDescription: "an hour, 100/100/40 sets", start: start, span: 3_600, sets: [100, 100, 40], shares: true),
        Case(testDescription: "a start off the whole second, 90.5 minutes", start: start + 0.25, span: 5_430.5,
             sets: [100, 100], shares: true),
        Case(testDescription: "four hours in seven pieces", start: start, span: 14_400,
             sets: Array(repeating: 60, count: 7), shares: true),
        Case(testDescription: "one piece with far fewer sets, an hour", start: start, span: 3_600, sets: [150, 2, 150],
             shares: true),
        Case(testDescription: "a last piece of one set, ten seconds", start: start, span: 10, sets: [150, 150, 1],
             lastEntries: 1, shares: true),
        Case(testDescription: "a last piece of one set, 3.5 seconds", start: start + 0.5, span: 3.5,
             sets: [100, 100, 1], lastEntries: 1, shares: true),
        Case(testDescription: "a first piece with no sets", start: start, span: 3_600, sets: [0, 100], shares: true),
        Case(testDescription: "no sets at all", start: start, span: 3_600, sets: [0, 0, 0], shares: true),
        Case(testDescription: "exactly a second a piece", start: start, span: 3, sets: [100, 100, 40], shares: true),
        Case(testDescription: "just under a second a piece", start: start, span: 2.999, sets: [100, 100, 40],
             shares: false),
        Case(testDescription: "a span shorter than the pieces", start: start, span: 2, sets: [100, 100, 40],
             shares: false),
        Case(testDescription: "an end at the start", start: start, span: 0, sets: [100, 100], shares: false),
        Case(testDescription: "an end before the start", start: start, span: -60, sets: [100, 100], shares: false),
        Case(testDescription: "no end time (Fitbod, FitNotes)", start: start, span: nil, sets: [100, 100, 40],
             shares: false),
    ]

    /// A source whose split gives pieces with `sets` sets each, spread over each piece's exercises.
    private static func source(_ row: Case) -> ImportedWorkout {
        let entries = row.sets.enumerated().flatMap { piece, sets in
            let count = piece == row.sets.count - 1 ? row.lastEntries : DomainLimits.workoutEntriesMax
            return (0..<count).map { index in
                ImportedEntry(exerciseName: "Ex \(piece).\(index)",
                              sets: (0..<(sets / count + (index < sets % count ? 1 : 0))).map {
                                  ImportedSet(weightKg: 60, reps: $0 + 1)
                              })
            }
        }
        return ImportedWorkout(id: UUID(), startedAt: row.start, entries: entries, name: "Big day",
                               endedAt: row.span.map { row.start + $0 })
    }

    @Test(arguments: cases)
    func thePiecesTimes(row: Case) throws {
        let source = Self.source(row)
        let pieces = ImportSplit.pieces(source)
        #expect(pieces.map { $0.entries.reduce(0) { $0 + $1.sets.count } } == row.sets)
        #expect(pieces.first?.startedAt == source.startedAt)
        for (piece, next) in zip(pieces, pieces.dropFirst()) {
            #expect(piece.startedAt < next.startedAt, "starts strictly increase")
        }
        if row.shares {
            let end = try #require(source.endedAt)
            #expect(pieces.last?.endedAt == end, "the last piece ends at the source's end")
            for (piece, next) in zip(pieces, pieces.dropFirst()) {
                #expect(piece.endedAt == next.startedAt, "no overlap and no gap")
            }
            let durations = try pieces.map { try #require($0.endedAt).timeIntervalSince($0.startedAt) }
            #expect(durations.allSatisfy { $0 >= 1 }, "every piece lasts a second or more: \(durations)")
            #expect(abs(durations.reduce(0, +) - end.timeIntervalSince(source.startedAt)) < 0.001,
                    "the durations sum to the span")
        } else {
            #expect(pieces.map(\.startedAt) == pieces.indices.map { source.startedAt + TimeInterval($0) })
            #expect(pieces.allSatisfy { $0.endedAt == source.endedAt }, "each piece keeps the source's end")
        }
    }
}
