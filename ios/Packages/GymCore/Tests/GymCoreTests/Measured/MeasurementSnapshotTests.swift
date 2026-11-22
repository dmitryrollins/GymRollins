import Foundation
import Testing
@testable import GymCore

/// Plan 40, spec §6.1: the row saved and synced for a workout, and the limits migration 0014 CHECKs.
@Suite struct MeasurementSnapshotTests {
    private let id = UUID(uuidString: "00000000-0000-4000-8000-0000000000f1")!
    private let at = ISO8601DateFormatter().date(from: "2026-09-19T18:58:20Z")!

    private func row(workoutId: UUID? = nil, recordedBy: MeasurementSnapshot.RecordedBy? = .watch,
                     durationS: Double? = 3_500, activeKcal: Double? = 412, totalKcal: Double? = 489,
                     avgHr: Int? = 128, maxHr: Int? = 162, postHr: Int? = 124, effort: Int? = 6,
                     estimated: Bool = false, at date: Date? = nil) -> MeasurementSnapshot {
        MeasurementSnapshot(workoutId: workoutId ?? id, recordedBy: recordedBy, durationS: durationS,
                            activeKcal: activeKcal, totalKcal: totalKcal, avgHr: avgHr, maxHr: maxHr, postHr: postHr,
                            effort: effort, effortEstimated: estimated, clientUpdatedAt: date ?? at)
    }

    @Test func aReReadThatChangedNothingHasTheSameNumbers() {
        #expect(row().sameNumbers(as: row(at: at.addingTimeInterval(3_600))))
        #expect(!row().sameNumbers(as: row(workoutId: UUID())))
        #expect(!row().sameNumbers(as: row(recordedBy: .appleWorkout)))
        #expect(!row().sameNumbers(as: row(durationS: 3_501)))
        #expect(!row().sameNumbers(as: row(activeKcal: 413)))
        #expect(!row().sameNumbers(as: row(totalKcal: nil)))
        #expect(!row().sameNumbers(as: row(avgHr: 129)))
        #expect(!row().sameNumbers(as: row(maxHr: 161)))
        #expect(!row().sameNumbers(as: row(postHr: nil)))
        #expect(!row().sameNumbers(as: row(effort: 7)))
        #expect(!row().sameNumbers(as: row(estimated: true)))
    }

    @Test func theSampleFitsAndSoDoesARowOfOnlyHeartRate() {
        #expect(row().isValid)
        #expect(row(recordedBy: nil, durationS: nil, activeKcal: nil, totalKcal: nil, postHr: nil, effort: nil).isValid)
    }

    @Test func aValueOutsideItsLimitDoesnt() {
        #expect(!row(durationS: 86_401).isValid)
        #expect(!row(durationS: -1).isValid)
        #expect(!row(durationS: .nan).isValid)
        #expect(!row(activeKcal: 20_001).isValid)
        #expect(!row(totalKcal: -0.5).isValid)
        #expect(!row(avgHr: 19).isValid)
        #expect(!row(maxHr: 251).isValid)
        #expect(!row(postHr: 300).isValid)
        #expect(!row(effort: 0).isValid)
        #expect(!row(effort: 11).isValid)
    }

    @Test func theLimitsAndWireNamesAreMigration0014s() {
        #expect(MeasurementLimits.durationS == 0...86_400)
        #expect(MeasurementLimits.kcal == 0...20_000)
        #expect(MeasurementLimits.heartRate == 20...250)
        #expect(MeasurementLimits.effort == 1...10)
        #expect(MeasurementSnapshot.RecordedBy.watch.rawValue == "watch")
        #expect(MeasurementSnapshot.RecordedBy.appleWorkout.rawValue == "apple_workout")
    }
}
