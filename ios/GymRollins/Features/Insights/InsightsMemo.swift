import Foundation
import GymCore

/// The insights snapshot and the resolved outside workouts, kept on `AppEnvironment` until what they were made from
/// may have changed. Today's streak chip and recovery card, Log and Body each ask on every refresh (and on every return
/// to the app); with two years of outside workouts, resolving them alone took tens of milliseconds on the main thread.
struct InsightsMemo {
    /// The stored data both are made from. `revision` bumps with every write the app makes (and every sync that brought
    /// rows); the counts also catch a row added or deleted without one, e.g. a Health import that a newer one overtook.
    struct DataKey: Equatable {
        let revision: Int
        let readsOutsideWorkouts: Bool
        let workouts: Int
        let outsideWorkouts: Int
    }

    /// What a snapshot was made from besides the data: the plan, goal and limits note (`insightsRevision`), the time
    /// zone, and the minute. Recovery moves with time, so a snapshot is reused within its minute only (the cards
    /// themselves refresh every 10 minutes).
    struct SnapshotKey: Equatable {
        let data: DataKey
        let revision: String
        let timeZone: String
        let minute: Int
    }

    var resolved: (key: DataKey, value: ResolvedActivities)?
    var snapshot: (key: SnapshotKey, value: InsightsSnapshot)?
}
