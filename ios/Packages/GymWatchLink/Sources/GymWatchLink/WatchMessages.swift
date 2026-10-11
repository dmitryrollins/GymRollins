import Foundation

/// The phone <-> watch protocol version. Bump it for a change an older peer can't decode; a peer ignores payloads with a
/// newer version (and logs it) instead of misreading them.
public enum WatchProtocol {
    public static let version = 1
}

public enum WatchWeightUnit: String, Codable, Sendable {
    case kg, lb
}

/// The loadable totals for one exercise, in the user's unit: `offset + k × step` (a 45 lb bar with 5 lb plates is
/// 5 + k × 10). The Digital Crown moves along it.
public struct WatchLoadGrid: Codable, Sendable, Equatable {
    public let unit: WatchWeightUnit
    public let step: Double
    public let offset: Double

    public init(unit: WatchWeightUnit, step: Double, offset: Double) {
        self.unit = unit
        self.step = step
        self.offset = offset
    }
}

public struct WatchRest: Codable, Sendable, Equatable {
    public let startedAt: Date
    public let endsAt: Date

    public init(startedAt: Date, endsAt: Date) {
        self.startedAt = startedAt
        self.endsAt = endsAt
    }
}

/// The set a Log set tap completes: the next undone set of the exercise the phone shows (Live Activity rules).
public struct WatchNextSet: Codable, Sendable, Equatable {
    public let entryId: UUID
    public let setId: UUID
    public let exerciseName: String
    /// "Set 3/5", "Warm-up 1/2".
    public let setLabel: String
    /// "135 lb × 8", "45 s", "20 min · 3.1 mi".
    public let setDetail: String
    /// Reps-based sets only (time and cardio sets are logged on the phone).
    public let canLog: Bool
    /// Planned weight in `grid.unit`, and planned reps.
    public let weight: Double
    public let reps: Int
    public let grid: WatchLoadGrid

    public init(entryId: UUID, setId: UUID, exerciseName: String, setLabel: String, setDetail: String, canLog: Bool,
                weight: Double, reps: Int, grid: WatchLoadGrid) {
        self.entryId = entryId
        self.setId = setId
        self.exerciseName = exerciseName
        self.setLabel = setLabel
        self.setDetail = setDetail
        self.canLog = canLog
        self.weight = weight
        self.reps = reps
        self.grid = grid
    }
}

/// The workout in progress on the phone.
public struct WatchWorkout: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let startedAt: Date
    /// Paused time so far (not counting a pause still running since `pausedAt`).
    public let pausedSeconds: TimeInterval
    public let pausedAt: Date?
    /// Nil once no set is left (then `status` says why: "All sets done", "Add an exercise").
    public let next: WatchNextSet?
    public let status: String
    public let rest: WatchRest?
    public let hasPrevious: Bool
    public let hasNext: Bool
    /// The phone accepted this watch's claim to write the workout to Apple Health.
    public let watchRecordsHealth: Bool

    public init(id: UUID, name: String, startedAt: Date, pausedSeconds: TimeInterval, pausedAt: Date?,
                next: WatchNextSet?, status: String, rest: WatchRest?, hasPrevious: Bool, hasNext: Bool,
                watchRecordsHealth: Bool) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.pausedSeconds = pausedSeconds
        self.pausedAt = pausedAt
        self.next = next
        self.status = status
        self.rest = rest
        self.hasPrevious = hasPrevious
        self.hasNext = hasNext
        self.watchRecordsHealth = watchRecordsHealth
    }
}

/// How the last workout ended (kept in every state, so a watch that missed the moment still learns it).
public struct WatchEndedWorkout: Codable, Sendable, Equatable {
    public let workoutId: UUID
    public let endedAt: Date
    /// False: discarded (nothing is saved anywhere).
    public let finished: Bool
    /// The watch's Health claim was accepted: the watch saves the Health workout and the phone doesn't.
    public let watchRecordsHealth: Bool
    /// When the owner tapped Finish. Usually `endedAt`, but a workout ended at its last set long before (`IdleFinish`)
    /// has an earlier `endedAt`; time windows run from this. Nil from a phone build that predates it.
    public let finishedAt: Date?

    public init(workoutId: UUID, endedAt: Date, finished: Bool, watchRecordsHealth: Bool, finishedAt: Date? = nil) {
        self.workoutId = workoutId
        self.endedAt = endedAt
        self.finished = finished
        self.watchRecordsHealth = watchRecordsHealth
        self.finishedAt = finishedAt
    }
}

/// Today's plan while no workout runs.
public struct WatchToday: Codable, Sendable, Equatable {
    public let title: String
    public let canStart: Bool

    public init(title: String, canStart: Bool) {
        self.title = title
        self.canStart = canStart
    }
}

/// Everything the watch shows, phone → watch. Latest wins (`sentAt`).
public struct WatchState: Codable, Sendable, Equatable {
    public let sentAt: Date
    public let workout: WatchWorkout?
    public let lastEnded: WatchEndedWorkout?
    public let today: WatchToday?
    /// Apple Health is on in the phone app.
    public let healthEnabled: Bool

    public init(sentAt: Date, workout: WatchWorkout?, lastEnded: WatchEndedWorkout?, today: WatchToday?,
                healthEnabled: Bool) {
        self.sentAt = sentAt
        self.workout = workout
        self.lastEnded = lastEnded
        self.today = today
        self.healthEnabled = healthEnabled
    }

    /// Same content, whenever it was sent (the phone only pushes real changes).
    public func hasSameContent(as other: WatchState) -> Bool {
        workout == other.workout && lastEnded == other.lastEnded && today == other.today
            && healthEnabled == other.healthEnabled
    }
}

public enum WatchDirection: String, Codable, Sendable {
    case previous, next
}

/// What the watch asks the phone to do. Workout actions name the workout, entry, set or rest they were made for, so the
/// phone ignores a stale one (a queued tap that arrives after things moved on).
public enum WatchAction: Codable, Sendable, Equatable {
    /// Complete `setId` (still the entry's next set) with `weight` (in `unit`) × `reps`.
    case logSet(workoutId: UUID, entryId: UUID, setId: UUID, weight: Double, unit: WatchWeightUnit, reps: Int)
    case extendRest(workoutId: UUID, entryId: UUID?, restStartedAt: Date, seconds: TimeInterval)
    case skipRest(workoutId: UUID, entryId: UUID?, restStartedAt: Date)
    /// Show the exercise before/after `fromEntryId` (only while that is the one the phone shows).
    case showExercise(workoutId: UUID, fromEntryId: UUID, direction: WatchDirection)
    /// Start today's planned workout (only when none is running).
    case startToday
    /// The watch's workout session runs for `workoutId` and would like to write the Health workout.
    case healthClaim(workoutId: UUID)
    /// The watch saved the Health workout for `workoutId`.
    case healthRecorded(workoutId: UUID, averageHeartRate: Double?, maxHeartRate: Double?)
    /// Send the current state now.
    case requestState

    public var workoutId: UUID? {
        switch self {
        case .logSet(let id, _, _, _, _, _), .extendRest(let id, _, _, _), .skipRest(let id, _, _),
             .showExercise(let id, _, _), .healthClaim(let id), .healthRecorded(let id, _, _):
            id
        case .startToday, .requestState:
            nil
        }
    }
}

/// One watch → phone message. `id` makes it idempotent: a command delivered twice (sendMessage whose reply was lost,
/// then its transferUserInfo fallback) is applied once.
public struct WatchCommand: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let issuedAt: Date
    public let action: WatchAction

    public init(id: UUID = UUID(), issuedAt: Date = Date(), action: WatchAction) {
        self.id = id
        self.issuedAt = issuedAt
        self.action = action
    }
}

/// WatchConnectivity payloads: `["v": version, "type": "state" | "command", "data": JSON]` (property-list values only).
public enum WatchEnvelope {
    public enum Decoded: Sendable, Equatable {
        case state(WatchState)
        case command(WatchCommand)
    }

    public enum DecodingError: Error, Equatable {
        case unsupportedVersion(Int)
        case malformed
    }

    static let versionKey = "v"
    static let typeKey = "type"
    static let dataKey = "data"

    public static func encode(_ state: WatchState) throws -> [String: Any] {
        [versionKey: WatchProtocol.version, typeKey: "state", dataKey: try JSONEncoder().encode(state)]
    }

    public static func encode(_ command: WatchCommand) throws -> [String: Any] {
        [versionKey: WatchProtocol.version, typeKey: "command", dataKey: try JSONEncoder().encode(command)]
    }

    public static func decode(_ payload: [String: Any]) throws -> Decoded {
        guard let version = payload[versionKey] as? Int else { throw DecodingError.malformed }
        guard version <= WatchProtocol.version else { throw DecodingError.unsupportedVersion(version) }
        guard let type = payload[typeKey] as? String, let data = payload[dataKey] as? Data else {
            throw DecodingError.malformed
        }
        switch type {
        case "state": return .state(try decode(WatchState.self, from: data))
        case "command": return .command(try decode(WatchCommand.self, from: data))
        default: throw DecodingError.malformed
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(type, from: data) else { throw DecodingError.malformed }
        return value
    }
}
