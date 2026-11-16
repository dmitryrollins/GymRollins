import Foundation
import GymCore
import SwiftData

/// An outside workout read from Apple Health (plan 39). The id is the HealthKit workout's UUID. A deletion in Health
/// leaves a tombstone, which keeps the import from bringing the workout back.
@Model
public final class HealthActivityRecord {
    @Attribute(.unique) public var id: UUID
    public var kind: String
    public var startedAt: Date
    public var endedAt: Date
    public var durationS: Double
    public var kcal: Double?
    public var distanceM: Double?
    public var avgHr: Int?
    public var maxHr: Int?
    public var sourceName: String
    public var fromWatch: Bool
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool
    public var deletedAt: Date?

    public init(_ activity: HealthActivity, now: Date) {
        self.id = activity.id
        self.kind = activity.kind
        self.startedAt = activity.startedAt
        self.endedAt = activity.endedAt
        self.durationS = activity.durationS
        self.kcal = activity.kcal
        self.distanceM = activity.distanceM
        self.avgHr = activity.avgHr
        self.maxHr = activity.maxHr
        self.sourceName = activity.sourceName
        self.fromWatch = activity.fromWatch
        self.updatedAt = now
        self.dirty = true
    }

    public var value: HealthActivity {
        HealthActivity(id: id, kind: kind, startedAt: startedAt, endedAt: endedAt, durationS: durationS, kcal: kcal,
                       distanceM: distanceM, avgHr: avgHr, maxHr: maxHr, sourceName: sourceName, fromWatch: fromWatch)
    }

    /// Takes every field of `activity` (the id stays).
    func apply(_ activity: HealthActivity) {
        kind = activity.kind
        startedAt = activity.startedAt
        endedAt = activity.endedAt
        durationS = activity.durationS
        kcal = activity.kcal
        distanceM = activity.distanceM
        avgHr = activity.avgHr
        maxHr = activity.maxHr
        sourceName = activity.sourceName
        fromWatch = activity.fromWatch
    }
}

/// One local day of activity read from Apple Health (plan 39), keyed by `YYYY-MM-DD`. Never deleted: a day stays as
/// it was last read.
@Model
public final class ActivityDayRecord {
    @Attribute(.unique) public var day: String
    public var steps: Int
    public var moveKcal: Double
    public var exerciseMin: Int
    public var standH: Int?
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool

    public init(_ activityDay: ActivityDay, now: Date) {
        self.day = activityDay.day
        self.steps = activityDay.steps
        self.moveKcal = activityDay.moveKcal
        self.exerciseMin = activityDay.exerciseMin
        self.standH = activityDay.standH
        self.updatedAt = now
        self.dirty = true
    }

    public var value: ActivityDay {
        ActivityDay(day: day, steps: steps, moveKcal: moveKcal, exerciseMin: exerciseMin, standH: standH)
    }

    /// Takes every value of `activityDay` (the day stays).
    func apply(_ activityDay: ActivityDay) {
        steps = activityDay.steps
        moveKcal = activityDay.moveKcal
        exerciseMin = activityDay.exerciseMin
        standH = activityDay.standH
    }
}
