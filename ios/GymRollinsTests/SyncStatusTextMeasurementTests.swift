import GymData
import Testing
@testable import GymRollins

/// Plan 40: the measured numbers' sync kind has a name wherever a refused row is listed (Account › "couldn't sync").
@Suite struct SyncStatusTextMeasurementTests {
    @Test func theNewKindIsNamed() {
        #expect(SyncStatusText.entityName(.workoutMeasurements) == "Workout measurements")
        #expect(SyncStatusText.entityPlural(.workoutMeasurements) == "workout measurements")
    }
}
