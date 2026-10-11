import Foundation
import SwiftData

@Model
public final class WorkoutRecord {
    @Attribute(.unique) public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var pausedSeconds: Double
    public var pausedAt: Date?
    public var routineId: UUID?
    public var name: String
    public var sourceRaw: String
    public var note: String?
    /// True while the workout is in progress (never synced while active).
    public var isActive: Bool
    public var volumeKg: Double
    @Relationship(deleteRule: .cascade, inverse: \WorkoutEntryRecord.workout)
    public var entries: [WorkoutEntryRecord] = []
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool
    public var deletedAt: Date?
    /// JSON-encoded `[PersonalRecord]` set by `WorkoutRepository.save(_:records:)`. Non-empty saves
    /// overwrite it; empty ones leave the existing value so editing a workout later doesn't erase it.
    public var recordsData: Data?
    /// JSON-encoded `[WorkoutEntry]`: a read cache of `entries` (with their sets), written together with them by
    /// `setEntries(_:in:)` (the only way entries are replaced). Reading a workout from it avoids materializing and
    /// faulting ~13 entry/set rows per workout, which made `recent(limit: 50)` take ~100 ms with 150 workouts
    /// (docs/testing/performance.md). nil for rows written before it existed: readers fall back to `entries`.
    public var entriesData: Data?

    public init(id: UUID, startedAt: Date, name: String, sourceRaw: String, isActive: Bool, now: Date) {
        self.id = id
        self.startedAt = startedAt
        self.pausedSeconds = 0
        self.name = name
        self.sourceRaw = sourceRaw
        self.isActive = isActive
        self.volumeKg = 0
        self.updatedAt = now
        self.dirty = true
    }
}

@Model
public final class WorkoutEntryRecord {
    @Attribute(.unique) public var id: UUID
    public var exerciseId: String
    public var position: Int
    public var note: String?
    public var supersetGroup: String?
    @Relationship(deleteRule: .cascade, inverse: \SetRecord.entry)
    public var sets: [SetRecord] = []
    public var workout: WorkoutRecord?

    public init(id: UUID, exerciseId: String, position: Int, note: String?, supersetGroup: String?) {
        self.id = id
        self.exerciseId = exerciseId
        self.position = position
        self.note = note
        self.supersetGroup = supersetGroup
    }
}

@Model
public final class SetRecord {
    @Attribute(.unique) public var id: UUID
    public var position: Int
    public var weightKg: Double
    public var reps: Int
    public var sec: Int?
    public var minutes: Double?
    public var distanceM: Double?
    public var done: Bool
    public var warmup: Bool
    public var rir: Double?
    public var rpe: Double?
    public var multiplier: Double
    public var completedAt: Date?
    public var entry: WorkoutEntryRecord?

    public init(id: UUID, position: Int, weightKg: Double, reps: Int, sec: Int?, minutes: Double?, distanceM: Double?,
                done: Bool, warmup: Bool, rir: Double?, rpe: Double?, multiplier: Double, completedAt: Date?) {
        self.id = id
        self.position = position
        self.weightKg = weightKg
        self.reps = reps
        self.sec = sec
        self.minutes = minutes
        self.distanceM = distanceM
        self.done = done
        self.warmup = warmup
        self.rir = rir
        self.rpe = rpe
        self.multiplier = multiplier
        self.completedAt = completedAt
    }
}
