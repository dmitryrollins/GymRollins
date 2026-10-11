import Foundation

public enum ProgressionPolicy: String, Codable, Sendable, CaseIterable {
    case off, linear, greyskull, double, time

    /// The policy that makes sense for an exercise of `mode`: timed exercises progress by time (unless off), cardio
    /// has no load progression (its duration target is kept), rep exercises use the policy as is.
    public func effective(for mode: ExerciseMode) -> ProgressionPolicy {
        switch mode {
        case .reps: self
        case .time: self == .off ? .off : .time
        case .cardio: .off
        }
    }
}

public struct RoutineExercise: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let exerciseId: String
    public let sets: Int
    public let reps: Int
    public let repsMin: Int?
    public let sec: Int?
    public let weightKg: Double?
    public let mode: ExerciseMode
    public let policy: ProgressionPolicy?
    public let incKg: Double?
    public let supersetGroup: String?
    /// When `weightKg` was last set by the user or Claude; gates the `.planned` progression override.
    public let weightSetAt: Date?

    public init(id: UUID = UUID(), exerciseId: String, sets: Int, reps: Int, repsMin: Int? = nil, sec: Int? = nil,
                weightKg: Double? = nil, mode: ExerciseMode = .reps, policy: ProgressionPolicy? = nil,
                incKg: Double? = nil, supersetGroup: String? = nil, weightSetAt: Date? = nil) {
        self.id = id
        self.exerciseId = exerciseId
        self.sets = sets
        self.reps = reps
        self.repsMin = repsMin
        self.sec = sec
        self.weightKg = weightKg
        self.mode = mode
        self.policy = policy
        self.incKg = incKg
        self.supersetGroup = supersetGroup
        self.weightSetAt = weightSetAt
    }

    enum CodingKeys: String, CodingKey {
        case id, exerciseId, sets, reps, repsMin, sec, weightKg, mode, policy, incKg, supersetGroup, weightSetAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            exerciseId: try c.decode(String.self, forKey: .exerciseId),
            sets: try c.decode(Int.self, forKey: .sets),
            reps: try c.decode(Int.self, forKey: .reps),
            repsMin: try c.decodeIfPresent(Int.self, forKey: .repsMin),
            sec: try c.decodeIfPresent(Int.self, forKey: .sec),
            weightKg: try c.decodeIfPresent(Double.self, forKey: .weightKg),
            mode: try c.decodeIfPresent(ExerciseMode.self, forKey: .mode) ?? .reps,
            policy: try c.decodeIfPresent(ProgressionPolicy.self, forKey: .policy),
            incKg: try c.decodeIfPresent(Double.self, forKey: .incKg),
            supersetGroup: try c.decodeIfPresent(String.self, forKey: .supersetGroup),
            weightSetAt: try c.decodeIfPresent(Date.self, forKey: .weightSetAt)
        )
    }
}

public struct Routine: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let emoji: String?
    public let policy: ProgressionPolicy
    public let paused: Bool
    public let exercises: [RoutineExercise]

    public init(id: UUID = UUID(), name: String, emoji: String? = nil, policy: ProgressionPolicy = .double,
                paused: Bool = false, exercises: [RoutineExercise] = []) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.policy = policy
        self.paused = paused
        self.exercises = exercises
    }

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, policy, paused, exercises
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            emoji: try c.decodeIfPresent(String.self, forKey: .emoji),
            policy: try c.decodeIfPresent(ProgressionPolicy.self, forKey: .policy) ?? .double,
            paused: try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false,
            exercises: try c.decodeIfPresent([RoutineExercise].self, forKey: .exercises) ?? []
        )
    }
}
