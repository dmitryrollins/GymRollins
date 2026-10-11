public enum PlanChangeType: String, Codable, Sendable, CaseIterable {
    case addExercise = "add-exercise"
    case removeExercise = "remove-exercise"
    case swapExercise = "swap-exercise"
    case sets, reps, repsMin, sec, weight, cardio, reorder, superset
    case routineProg = "routine-prog"
    case exerciseProg = "exercise-prog"
    case inc
    case addRoutine = "add-routine"
    case removeRoutine = "remove-routine"
    case renameRoutine = "rename-routine"
    case pauseRoutine = "pause-routine"
    case week
    /// A one-off routine for one date (`date`, the owner's yyyy-MM-dd): Today shows it on that date only, like Switch.
    case today
}

/// One proposed plan edit. Field names are the JSON contract shared with the MCP server.
public struct PlanChange: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let type: PlanChangeType
    public let routineId: String?
    public let exerciseId: String?
    public let toExerciseId: String?
    public let withExerciseId: String?
    public let sets: Int?
    public let reps: Int?
    public let repsMin: Int?
    public let sec: Int?
    public let weightKg: Double?
    public let minutes: Double?
    public let speed: Double?
    public let incKg: Double?
    public let policy: ProgressionPolicy?
    public let position: Int?
    public let name: String?
    public let weekday: Int?
    public let paused: Bool?
    /// `today` only: the owner's local date (yyyy-MM-dd) the routine is for.
    public let date: String?
    public let reason: String?

    public init(id: String, type: PlanChangeType, routineId: String? = nil, exerciseId: String? = nil,
                toExerciseId: String? = nil, withExerciseId: String? = nil, sets: Int? = nil, reps: Int? = nil,
                repsMin: Int? = nil, sec: Int? = nil, weightKg: Double? = nil, minutes: Double? = nil,
                speed: Double? = nil, incKg: Double? = nil, policy: ProgressionPolicy? = nil, position: Int? = nil,
                name: String? = nil, weekday: Int? = nil, paused: Bool? = nil, date: String? = nil,
                reason: String? = nil) {
        self.id = id
        self.type = type
        self.routineId = routineId
        self.exerciseId = exerciseId
        self.toExerciseId = toExerciseId
        self.withExerciseId = withExerciseId
        self.sets = sets
        self.reps = reps
        self.repsMin = repsMin
        self.sec = sec
        self.weightKg = weightKg
        self.minutes = minutes
        self.speed = speed
        self.incKg = incKg
        self.policy = policy
        self.position = position
        self.name = name
        self.weekday = weekday
        self.paused = paused
        self.date = date
        self.reason = reason
    }
}

public struct PlanProposal: Codable, Sendable, Equatable {
    public let summary: String
    public let changes: [PlanChange]

    public init(summary: String, changes: [PlanChange]) {
        self.summary = summary
        self.changes = changes
    }
}

public struct PlanSnapshot: Codable, Sendable, Equatable {
    public struct RoutineRef: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let exerciseIds: [String]
        /// Effective top-of-range reps per exerciseId, when known.
        public let reps: [String: Int]?
        /// Effective bottom-of-range reps per exerciseId, when known.
        public let repsMin: [String: Int]?
        /// Paused routines can't be picked for a `today` change (nil: not paused).
        public let paused: Bool?

        public init(id: String, name: String, exerciseIds: [String], reps: [String: Int]? = nil,
                    repsMin: [String: Int]? = nil, paused: Bool? = nil) {
            self.id = id
            self.name = name
            self.exerciseIds = exerciseIds
            self.reps = reps
            self.repsMin = repsMin
            self.paused = paused
        }

        enum CodingKeys: String, CodingKey {
            case id, name, exerciseIds, reps, repsMin, paused
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                exerciseIds: try c.decode([String].self, forKey: .exerciseIds),
                reps: try c.decodeIfPresent([String: Int].self, forKey: .reps),
                repsMin: try c.decodeIfPresent([String: Int].self, forKey: .repsMin),
                paused: try c.decodeIfPresent(Bool.self, forKey: .paused)
            )
        }
    }

    public let routines: [RoutineRef]

    public init(routines: [RoutineRef]) { self.routines = routines }
}

public struct PlanViolation: Codable, Sendable, Equatable {
    public let changeId: String?
    public let field: String
    public let message: String

    public init(changeId: String?, field: String, message: String) {
        self.changeId = changeId
        self.field = field
        self.message = message
    }
}

/// Value ranges a plan change may carry — shared by `PlanChangeValidator` and, as defense in depth,
/// `PlanChangeApplier` (which must throw, never trap, on a value it cannot store). Mirrored in
/// supabase/functions/_shared/plan-validation.ts.
public enum PlanChangeLimits {
    public static let sets = 1...10
    public static let reps = 1...100
    public static let sec = 5...3600
    public static let minutes: ClosedRange<Double> = 1...300
    public static let speed: ClosedRange<Double> = 0...50
    public static let weightKg: ClosedRange<Double> = 0...500
    public static let incKg: ClosedRange<Double> = 0.1...20
    public static let position = 0...(DomainLimits.routineExercisesMax - 1)
    /// How many days after the owner's date a `today` change may be for (0 = today).
    public static let todayDaysAhead = 0...7
}
