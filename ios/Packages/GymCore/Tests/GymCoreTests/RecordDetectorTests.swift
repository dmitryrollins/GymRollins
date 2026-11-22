import Foundation
import Testing
@testable import GymCore

@Suite struct RecordDetectorTests {
    private let benchSession = Workout(startedAt: .now, name: "Push + Biceps", entries: [
        WorkoutEntry(exerciseId: "bench", sets: [
            WorkoutSet(weightKg: 68.039, reps: 10, done: true),
            WorkoutSet(weightKg: 68.039, reps: 10, done: true),
            WorkoutSet(weightKg: 68.039, reps: 10, done: true),
        ]),
    ])

    @Test func sampleBenchSessionBeatsPriorWeek() throws {
        // 12 Sep: 3 x 6 @ 68.039 kg (e1RM 81.65, volume 1225)
        let previous = ["bench": ExerciseBests(e1RMKg: 81.65, repsAtWeight: [68_039: 6], volumeKg: 1_224.7)]
        let records = RecordDetector.records(for: benchSession, previous: previous)
        #expect(Set(records.map(\.kind)) == [.e1RM, .repsAtWeight, .volume])
        let reps = try #require(records.first { $0.kind == .repsAtWeight })
        #expect(reps.reps == 10)
    }

    @Test func noRecordsWithoutHistory() {
        #expect(RecordDetector.records(for: benchSession, previous: [:]).isEmpty)
    }

    @Test func noRecordWhenNotBeaten() {
        let previous = ["bench": ExerciseBests(e1RMKg: 100, repsAtWeight: [68_039: 12], volumeKg: 5_000)]
        #expect(RecordDetector.records(for: benchSession, previous: previous).isEmpty)
    }

    @Test func bestsMergeKeepsMaxima() {
        let a = ExerciseBests(e1RMKg: 70, repsAtWeight: [60_000: 6], volumeKg: 1_000)
        let b = ExerciseBests(e1RMKg: 75, repsAtWeight: [60_000: 5, 62_500: 4], volumeKg: 900)
        let merged = a.merging(b)
        #expect(merged == ExerciseBests(e1RMKg: 75, repsAtWeight: [60_000: 6, 62_500: 4], volumeKg: 1_000))
    }

    @Test func bestsFromEntry() {
        let bests = ExerciseBests(entry: benchSession.entries[0])
        #expect(bests.repsAtWeight == [68_039: 10])
        #expect(abs(bests.volumeKg - 2_041.17) < 0.01)
    }

    /// `PersonalRecord`'s memberwise init must be public so other modules (GymData, GymRollins) can
    /// construct it directly, e.g. when round-tripping through persistence or test spies.
    @Test func personalRecordPublicInit() {
        let record = PersonalRecord(exerciseId: "0025", kind: .e1RM, valueKg: 90.7, reps: nil, weightKg: nil,
                                    previousKg: 81.6)
        #expect(record.exerciseId == "0025")
        #expect(record.kind == .e1RM)
        #expect(record.valueKg == 90.7)
        #expect(record.previousKg == 81.6)
    }

    @Test func repsAtWeightReturnsOneRecordPerQualifyingWeight() {
        // Beats prior at both 100 kg (3 -> 5) and 80 kg (8 -> 12); both should be reported, heaviest first.
        let session = Workout(startedAt: .now, name: "Legs", entries: [
            WorkoutEntry(exerciseId: "squat", sets: [
                WorkoutSet(weightKg: 100, reps: 5, done: true),
                WorkoutSet(weightKg: 80, reps: 12, done: true),
            ]),
        ])
        let previous = ["squat": ExerciseBests(e1RMKg: nil, repsAtWeight: [100_000: 3, 80_000: 8], volumeKg: 0)]
        let records = RecordDetector.records(for: session, previous: previous)
        let repRecords = records.filter { $0.kind == .repsAtWeight }
        #expect(repRecords.count == 2)
        #expect(repRecords.map(\.weightKg) == [100, 80])
        #expect(repRecords.map(\.reps) == [5, 12])
    }
}
