import Foundation

public enum WorkoutSource: String, Codable, Sendable {
    case app, `import`
}

public struct WorkoutSet: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let weightKg: Double
    /// The pound number the weight was entered or chosen as (`PoundWeight`); nil when none was given. It never
    /// disagrees with `weightKg`: the init drops one that does.
    public let weightLb: Double?
    public let reps: Int
    public let sec: Int?
    public let minutes: Double?
    public let distanceM: Double?
    public let done: Bool
    public let warmup: Bool
    public let rir: Double?
    public let rpe: Double?
    /// Volume multiplier (2 for a pair of dumbbells logged per hand).
    public let multiplier: Double
    public let completedAt: Date?

    public init(id: UUID = UUID(), weightKg: Double, weightLb: Double? = nil, reps: Int, sec: Int? = nil,
                minutes: Double? = nil, distanceM: Double? = nil, done: Bool = false, warmup: Bool = false,
                rir: Double? = nil, rpe: Double? = nil, multiplier: Double = 1, completedAt: Date? = nil) {
        self.id = id
        self.weightKg = weightKg
        self.weightLb = PoundWeight.agreeing(weightLb, kg: weightKg)
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

    /// The weight as kg and pound number.
    public var weight: PoundWeight { PoundWeight(kg: weightKg, lb: weightLb) }

    /// Returns a copy marked done at `date`.
    public func completing(at date: Date) -> WorkoutSet {
        WorkoutSet(id: id, weightKg: weightKg, weightLb: weightLb, reps: reps, sec: sec, minutes: minutes,
                   distanceM: distanceM, done: true, warmup: warmup, rir: rir, rpe: rpe, multiplier: multiplier,
                   completedAt: date)
    }

    enum CodingKeys: String, CodingKey {
        case id, weightKg, weightLb, reps, sec, minutes, distanceM, done, warmup, rir, rpe, multiplier, completedAt
    }

    /// Custom decode so imported/older payloads that omit a defaulted property (e.g. `done`)
    /// fall back to the same default as the memberwise init, instead of throwing keyNotFound. A `weightLb` that
    /// disagrees with `weightKg` is dropped by the init.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            weightKg: try c.decode(Double.self, forKey: .weightKg),
            weightLb: try c.decodeIfPresent(Double.self, forKey: .weightLb),
            reps: try c.decode(Int.self, forKey: .reps),
            sec: try c.decodeIfPresent(Int.self, forKey: .sec),
            minutes: try c.decodeIfPresent(Double.self, forKey: .minutes),
            distanceM: try c.decodeIfPresent(Double.self, forKey: .distanceM),
            done: try c.decodeIfPresent(Bool.self, forKey: .done) ?? false,
            warmup: try c.decodeIfPresent(Bool.self, forKey: .warmup) ?? false,
            rir: try c.decodeIfPresent(Double.self, forKey: .rir),
            rpe: try c.decodeIfPresent(Double.self, forKey: .rpe),
            multiplier: try c.decodeIfPresent(Double.self, forKey: .multiplier) ?? 1,
            completedAt: try c.decodeIfPresent(Date.self, forKey: .completedAt)
        )
    }
}

public struct WorkoutEntry: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let exerciseId: String
    public let sets: [WorkoutSet]
    public let note: String?
    public let supersetGroup: String?
    /// The listing whose loads this entry's weights were fitted to (a local row id); nil with no gym or no listing.
    public let gymListingId: UUID?

    public init(id: UUID = UUID(), exerciseId: String, sets: [WorkoutSet] = [], note: String? = nil,
                supersetGroup: String? = nil, gymListingId: UUID? = nil) {
        self.id = id
        self.exerciseId = exerciseId
        self.sets = sets
        self.note = note
        self.supersetGroup = supersetGroup
        self.gymListingId = gymListingId
    }

    enum CodingKeys: String, CodingKey {
        case id, exerciseId, sets, note, supersetGroup, gymListingId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            exerciseId: try c.decode(String.self, forKey: .exerciseId),
            sets: try c.decodeIfPresent([WorkoutSet].self, forKey: .sets) ?? [],
            note: try c.decodeIfPresent(String.self, forKey: .note),
            supersetGroup: try c.decodeIfPresent(String.self, forKey: .supersetGroup),
            gymListingId: try c.decodeIfPresent(UUID.self, forKey: .gymListingId)
        )
    }
}

public struct Workout: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let pausedSeconds: TimeInterval
    public let routineId: UUID?
    public let name: String
    public let entries: [WorkoutEntry]
    public let source: WorkoutSource
    public let note: String?
    /// The gym it was done at (a local row id); nil with no gym. The row may be gone: readers must cope.
    public let gymId: UUID?

    public init(id: UUID = UUID(), startedAt: Date, endedAt: Date? = nil, pausedSeconds: TimeInterval = 0,
                routineId: UUID? = nil, name: String, entries: [WorkoutEntry] = [], source: WorkoutSource = .app,
                note: String? = nil, gymId: UUID? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pausedSeconds = pausedSeconds
        self.routineId = routineId
        self.name = name
        self.entries = entries
        self.source = source
        self.note = note
        self.gymId = gymId
    }

    enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, pausedSeconds, routineId, name, entries, source, note, gymId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            startedAt: try c.decode(Date.self, forKey: .startedAt),
            endedAt: try c.decodeIfPresent(Date.self, forKey: .endedAt),
            pausedSeconds: try c.decodeIfPresent(TimeInterval.self, forKey: .pausedSeconds) ?? 0,
            routineId: try c.decodeIfPresent(UUID.self, forKey: .routineId),
            name: try c.decode(String.self, forKey: .name),
            entries: try c.decodeIfPresent([WorkoutEntry].self, forKey: .entries) ?? [],
            source: try c.decodeIfPresent(WorkoutSource.self, forKey: .source) ?? .app,
            note: try c.decodeIfPresent(String.self, forKey: .note),
            gymId: try c.decodeIfPresent(UUID.self, forKey: .gymId)
        )
    }
}
