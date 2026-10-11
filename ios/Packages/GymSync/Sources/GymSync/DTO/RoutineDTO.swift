import Foundation
import GymCore
import GymData

/// `public.routines`; the routine's exercises travel as the `exercises` jsonb array (aggregate sync).
public struct RoutineDTO: Codable, Sendable, Equatable, ServerStamped {
    public let id: UUID
    public let name: String
    public let emoji: String?
    public let policy: String
    public let position: Int
    public let paused: Bool
    public let exercises: [RoutineExerciseDTO]
    public let clientUpdatedAt: Date
    public let deletedAt: Date?
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, policy, position, paused, exercises
        case clientUpdatedAt = "client_updated_at", deletedAt = "deleted_at", updatedAt = "updated_at"
    }

    public init(_ row: SyncRow<RoutineSnapshot>) {
        let r = row.value.routine
        id = r.id
        name = r.name
        emoji = r.emoji
        policy = r.policy.rawValue
        position = row.value.position
        paused = r.paused
        exercises = r.exercises.enumerated().map { RoutineExerciseDTO($1, position: $0) }
        clientUpdatedAt = row.clientUpdatedAt
        deletedAt = row.deletedAt
        updatedAt = row.serverUpdatedAt
    }

    public func toDomain() -> SyncRow<RoutineSnapshot> {
        let routine = Routine(id: id, name: name, emoji: emoji, policy: ProgressionPolicy(rawValue: policy) ?? .double,
                              paused: paused, exercises: exercises.sorted { $0.position < $1.position }.map(\.domain))
        return SyncRow(value: RoutineSnapshot(routine: routine, position: position), clientUpdatedAt: clientUpdatedAt,
                       deletedAt: deletedAt, serverUpdatedAt: updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(emoji, forKey: .emoji)
        try c.encode(policy, forKey: .policy)
        try c.encode(position, forKey: .position)
        try c.encode(paused, forKey: .paused)
        try c.encode(exercises, forKey: .exercises)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
    }
}

/// One element of `routines.exercises` (spec §4 shape, plus `weight_set_at`).
public struct RoutineExerciseDTO: Codable, Sendable, Equatable {
    public let id: UUID
    public let exerciseId: String
    public let position: Int
    public let sets: Int
    public let reps: Int
    public let repsMin: Int?
    public let sec: Int?
    public let weightKg: Double?
    public let mode: String
    public let prog: String?
    public let incKg: Double?
    public let sg: String?
    public let weightSetAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, position, sets, reps, sec, mode, prog, sg
        case exerciseId = "exercise_id", repsMin = "reps_min", weightKg = "weight_kg", incKg = "inc_kg"
        case weightSetAt = "weight_set_at"
    }

    public init(_ e: RoutineExercise, position: Int) {
        id = e.id
        exerciseId = e.exerciseId
        self.position = position
        sets = e.sets
        reps = e.reps
        repsMin = e.repsMin
        sec = e.sec
        weightKg = e.weightKg
        mode = e.mode.rawValue
        prog = e.policy?.rawValue
        incKg = e.incKg
        sg = e.supersetGroup
        weightSetAt = e.weightSetAt
    }

    public var domain: RoutineExercise {
        RoutineExercise(id: id, exerciseId: exerciseId, sets: sets, reps: reps, repsMin: repsMin, sec: sec,
                        weightKg: weightKg, mode: ExerciseMode(rawValue: mode) ?? .reps,
                        policy: prog.flatMap(ProgressionPolicy.init(rawValue:)), incKg: incKg, supersetGroup: sg,
                        weightSetAt: weightSetAt)
    }
}
