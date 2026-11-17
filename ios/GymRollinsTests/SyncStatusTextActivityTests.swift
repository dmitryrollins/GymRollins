import GymData
import Testing
@testable import GymRollins

/// Plan 39: the two new sync kinds have names wherever a refused row is listed (Account › "couldn't sync").
@Suite struct SyncStatusTextActivityTests {
    @Test func theNewKindsAreNamed() {
        #expect(SyncStatusText.entityName(.healthActivities) == "Outside workout")
        #expect(SyncStatusText.entityPlural(.healthActivities) == "outside workouts")
        #expect(SyncStatusText.entityName(.activityDays) == "Day of activity")
        #expect(SyncStatusText.entityPlural(.activityDays) == "days of activity")
    }
}
