import Foundation
import GymCore

/// The synced aggregates, in push order (dependencies first).
public enum SyncEntity: String, CaseIterable, Sendable {
    case profile, customExercises, exercisePreferences, routines, weekSchedule, muscleTargets, bodyweight, workouts,
        proposals
}

/// One aggregate crossing the sync boundary.
///
/// Outgoing rows carry the device edit time (`clientUpdatedAt` = the record's `updatedAt`). Incoming rows also
/// carry the server's `updated_at` in `serverUpdatedAt`, which is stored locally to detect remote changes.
public struct SyncRow<Value: Sendable>: Sendable {
    public let value: Value
    public let clientUpdatedAt: Date
    public let deletedAt: Date?
    public let serverUpdatedAt: Date?

    public init(value: Value, clientUpdatedAt: Date, deletedAt: Date? = nil, serverUpdatedAt: Date? = nil) {
        self.value = value
        self.clientUpdatedAt = clientUpdatedAt
        self.deletedAt = deletedAt
        self.serverUpdatedAt = serverUpdatedAt
    }
}

extension SyncRow: Equatable where Value: Equatable {}

/// A routine plus its list position (which the `Routine` value does not carry).
public struct RoutineSnapshot: Sendable, Equatable {
    public let routine: Routine
    public let position: Int

    public init(routine: Routine, position: Int) {
        self.routine = routine
        self.position = position
    }
}

/// A finished workout plus the derived data stored with it.
public struct WorkoutSnapshot: Sendable, Equatable {
    public let workout: Workout
    public let records: [PersonalRecord]
    public let volumeKg: Double

    public init(workout: Workout, records: [PersonalRecord], volumeKg: Double) {
        self.workout = workout
        self.records = records
        self.volumeKg = volumeKg
    }
}

/// ISO weekday (1 = Monday … 7 = Sunday) -> routine (nil = rest).
public struct WeekdayAssignment: Sendable, Equatable {
    public let weekday: Int
    public let routineId: UUID?

    public init(weekday: Int, routineId: UUID?) {
        self.weekday = weekday
        self.routineId = routineId
    }
}

/// The profile exactly as stored (kg values, raw plate sizes) — lossless, unlike `Profile`, whose plate
/// inventory is converted and rounded into the display unit.
public struct ProfileSnapshot: Sendable, Equatable {
    public var unit: WeightUnit = .lb
    public var restSec = 120
    public var warmupRestSec = 60
    public var heightCm: Double?
    public var goalWeightKg: Double?
    public var goalDate: Date?
    public var trainingDays = 4
    public var experience = "intermediate"
    public var limits = ""
    public var deloadPct = 0.05
    public var barKg = 20.411656
    public var platesKg: [Double] = []
    public var dumbbellStepKg = 1.133981
    public var mcpReadWorkouts = true
    public var mcpReadBody = true
    public var mcpReadPlan = true
    public var mcpPropose = true
    public var mcpAutoApply = false
    public var sex: ProfileSex?
    public var birthYear: Int?

    public init() {}
}
