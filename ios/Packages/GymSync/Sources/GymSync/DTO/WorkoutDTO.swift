import Foundation
import GymCore
import GymData

/// A workout aggregate. Pushed as the `upsert_workout(payload)` body with nested `entries[].sets[]`; pulled from
/// `workouts?select=*,workout_entries(*,workout_sets(*))`, whose embed keys are also accepted on decode.
///
/// A push carries `base_updated_at` — the server `updated_at` this device last saw (nil if it never synced the
/// workout) — so the server answers `stale` when another device changed it since, and `force` only for the explicit
/// "Keep this iPhone's" resolution, which overwrites whatever the server holds.
public struct WorkoutDTO: Codable, Sendable, Equatable, ServerStamped {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let pausedSec: Double
    public let routineId: UUID?
    public let name: String
    public let source: String
    public let note: String?
    public let volKg: Double
    public let records: [PersonalRecord]
    public let entries: [WorkoutEntryDTO]
    public let clientUpdatedAt: Date
    public let deletedAt: Date?
    public var updatedAt: Date?
    /// Push only: the server version this edit was made on.
    public var baseUpdatedAt: Date?
    /// Push only: overwrite regardless of the base version (explicit keep-local conflict resolution).
    public var force = false

    enum CodingKeys: String, CodingKey {
        case id, name, source, note, records, entries
        case startedAt = "started_at", endedAt = "ended_at", pausedSec = "paused_sec", routineId = "routine_id"
        case volKg = "vol_kg", workoutEntries = "workout_entries"
        case clientUpdatedAt = "client_updated_at", deletedAt = "deleted_at", updatedAt = "updated_at"
        case baseUpdatedAt = "base_updated_at", force
    }

    public init(_ row: SyncRow<WorkoutSnapshot>, force: Bool = false) {
        let w = row.value.workout
        id = w.id
        startedAt = w.startedAt
        endedAt = w.endedAt
        pausedSec = w.pausedSeconds
        routineId = w.routineId
        name = w.name
        source = w.source.rawValue
        note = w.note
        volKg = row.value.volumeKg
        records = row.value.records
        entries = w.entries.enumerated().map { WorkoutEntryDTO($1, position: $0) }
        clientUpdatedAt = row.clientUpdatedAt
        deletedAt = row.deletedAt
        updatedAt = row.serverUpdatedAt
        baseUpdatedAt = row.serverUpdatedAt
        self.force = force
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        pausedSec = try c.decodeIfPresent(Double.self, forKey: .pausedSec) ?? 0
        routineId = try c.decodeIfPresent(UUID.self, forKey: .routineId)
        name = try c.decode(String.self, forKey: .name)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? WorkoutSource.app.rawValue
        note = try c.decodeIfPresent(String.self, forKey: .note)
        volKg = try c.decodeIfPresent(Double.self, forKey: .volKg) ?? 0
        records = try c.decodeIfPresent([PersonalRecord].self, forKey: .records) ?? []
        entries = try (c.decodeIfPresent([WorkoutEntryDTO].self, forKey: .entries)
            ?? c.decodeIfPresent([WorkoutEntryDTO].self, forKey: .workoutEntries) ?? [])
            .sorted { $0.position < $1.position }
        clientUpdatedAt = try c.decode(Date.self, forKey: .clientUpdatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        baseUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .baseUpdatedAt)
        force = try c.decodeIfPresent(Bool.self, forKey: .force) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt)
        try c.encode(pausedSec, forKey: .pausedSec)
        try c.encode(routineId, forKey: .routineId)
        try c.encode(name, forKey: .name)
        try c.encode(source, forKey: .source)
        try c.encode(note, forKey: .note)
        try c.encode(volKg, forKey: .volKg)
        try c.encode(records, forKey: .records)
        try c.encode(entries, forKey: .entries)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encode(baseUpdatedAt, forKey: .baseUpdatedAt)
        try c.encode(force, forKey: .force)
    }

    public func toDomain() -> SyncRow<WorkoutSnapshot> {
        let workout = Workout(id: id, startedAt: startedAt, endedAt: endedAt, pausedSeconds: pausedSec,
                              routineId: routineId, name: name, entries: entries.map(\.domain),
                              source: WorkoutSource(rawValue: source) ?? .app, note: note)
        return SyncRow(value: WorkoutSnapshot(workout: workout, records: records, volumeKg: volKg),
                       clientUpdatedAt: clientUpdatedAt, deletedAt: deletedAt, serverUpdatedAt: updatedAt)
    }
}

/// `public.workout_entries` row (nested `sets` on push, `workout_sets` embed on pull).
public struct WorkoutEntryDTO: Codable, Sendable, Equatable {
    public let id: UUID
    public let exerciseId: String
    public let position: Int
    public let note: String?
    public let supersetGroup: String?
    public let sets: [WorkoutSetDTO]

    enum CodingKeys: String, CodingKey {
        case id, position, note, sets
        case exerciseId = "exercise_id", supersetGroup = "superset_group", workoutSets = "workout_sets"
    }

    public init(_ e: WorkoutEntry, position: Int) {
        id = e.id
        exerciseId = e.exerciseId
        self.position = position
        note = e.note
        supersetGroup = e.supersetGroup
        sets = e.sets.enumerated().map { WorkoutSetDTO($1, position: $0) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        exerciseId = try c.decode(String.self, forKey: .exerciseId)
        position = try c.decode(Int.self, forKey: .position)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        supersetGroup = try c.decodeIfPresent(String.self, forKey: .supersetGroup)
        sets = try (c.decodeIfPresent([WorkoutSetDTO].self, forKey: .sets)
            ?? c.decodeIfPresent([WorkoutSetDTO].self, forKey: .workoutSets) ?? [])
            .sorted { $0.position < $1.position }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(exerciseId, forKey: .exerciseId)
        try c.encode(position, forKey: .position)
        try c.encode(note, forKey: .note)
        try c.encode(supersetGroup, forKey: .supersetGroup)
        try c.encode(sets, forKey: .sets)
    }

    public var domain: WorkoutEntry {
        WorkoutEntry(id: id, exerciseId: exerciseId, sets: sets.map(\.domain), note: note, supersetGroup: supersetGroup)
    }
}

/// `public.workout_sets` row.
public struct WorkoutSetDTO: Codable, Sendable, Equatable {
    public let id: UUID
    public let position: Int
    public let wKg: Double
    public let r: Int
    public let sec: Int?
    public let min: Double?
    public let distM: Double?
    public let done: Bool
    public let warmup: Bool
    public let rir: Double?
    public let rpe: Double?
    public let multiplier: Double
    public let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, position, r, sec, min, done, warmup, rir, rpe, multiplier
        case wKg = "w_kg", distM = "dist_m", completedAt = "completed_at"
    }

    public init(_ s: WorkoutSet, position: Int) {
        id = s.id
        self.position = position
        wKg = s.weightKg
        r = s.reps
        sec = s.sec
        min = s.minutes
        distM = s.distanceM
        done = s.done
        warmup = s.warmup
        rir = s.rir
        rpe = s.rpe
        multiplier = s.multiplier
        completedAt = s.completedAt
    }

    public var domain: WorkoutSet {
        WorkoutSet(id: id, weightKg: wKg, reps: r, sec: sec, minutes: min, distanceM: distM, done: done,
                   warmup: warmup, rir: rir, rpe: rpe, multiplier: multiplier, completedAt: completedAt)
    }
}
