import Foundation
import SwiftData

@Model
public final class RoutineRecord {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var emoji: String?
    public var policyRaw: String
    public var position: Int
    public var paused: Bool
    @Relationship(deleteRule: .cascade, inverse: \RoutineExerciseRecord.routine)
    public var exercises: [RoutineExerciseRecord] = []
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool
    public var deletedAt: Date?

    public init(id: UUID, name: String, emoji: String?, policyRaw: String, position: Int, paused: Bool, now: Date) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.policyRaw = policyRaw
        self.position = position
        self.paused = paused
        self.updatedAt = now
        self.dirty = true
    }
}

@Model
public final class RoutineExerciseRecord {
    @Attribute(.unique) public var id: UUID
    public var exerciseId: String
    public var position: Int
    public var sets: Int
    public var reps: Int
    public var repsMin: Int?
    public var sec: Int?
    public var weightKg: Double?
    /// When the plan weight was last set (user edit or applied proposal); drives the "planned" override.
    public var weightSetAt: Date?
    public var modeRaw: String
    public var policyRaw: String?
    public var incKg: Double?
    public var supersetGroup: String?
    public var routine: RoutineRecord?

    public init(id: UUID, exerciseId: String, position: Int, sets: Int, reps: Int, repsMin: Int?, sec: Int?,
                weightKg: Double?, weightSetAt: Date?, modeRaw: String, policyRaw: String?, incKg: Double?,
                supersetGroup: String?) {
        self.id = id
        self.exerciseId = exerciseId
        self.position = position
        self.sets = sets
        self.reps = reps
        self.repsMin = repsMin
        self.sec = sec
        self.weightKg = weightKg
        self.weightSetAt = weightSetAt
        self.modeRaw = modeRaw
        self.policyRaw = policyRaw
        self.incKg = incKg
        self.supersetGroup = supersetGroup
    }
}

/// ISO weekday 1 = Monday … 7 = Sunday. `routineId == nil` means rest day.
@Model
public final class WeekdayRecord {
    @Attribute(.unique) public var weekday: Int
    public var routineId: UUID?
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool

    public init(weekday: Int, routineId: UUID?, now: Date) {
        self.weekday = weekday
        self.routineId = routineId
        self.updatedAt = now
        self.dirty = true
    }
}
