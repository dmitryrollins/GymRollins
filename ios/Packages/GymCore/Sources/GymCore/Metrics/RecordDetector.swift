/// Weight key in grams, so float weights compare exactly.
public typealias WeightKey = Int

public func weightKey(_ kg: Double) -> WeightKey { Int((kg * 1_000).rounded()) }

public struct ExerciseBests: Sendable, Equatable, Codable {
    public let e1RMKg: Double?
    public let repsAtWeight: [WeightKey: Int]
    public let volumeKg: Double

    public init(e1RMKg: Double?, repsAtWeight: [WeightKey: Int], volumeKg: Double) {
        self.e1RMKg = e1RMKg
        self.repsAtWeight = repsAtWeight
        self.volumeKg = volumeKg
    }

    public init(entry: WorkoutEntry) {
        let sets = WorkoutMetrics.workingSets(entry)
        self.init(
            e1RMKg: WorkoutMetrics.bestE1RM(entry),
            repsAtWeight: sets.reduce(into: [:]) { acc, s in
                acc[weightKey(s.weightKg)] = max(acc[weightKey(s.weightKg)] ?? 0, s.reps)
            },
            volumeKg: WorkoutMetrics.volumeKg(entry)
        )
    }

    public func merging(_ other: ExerciseBests) -> ExerciseBests {
        let e1RM = [e1RMKg, other.e1RMKg].compactMap { $0 }.max()
        return ExerciseBests(e1RMKg: e1RM,
                             repsAtWeight: repsAtWeight.merging(other.repsAtWeight, uniquingKeysWith: max),
                             volumeKg: max(volumeKg, other.volumeKg))
    }
}

public enum RecordKind: String, Sendable, Codable {
    case e1RM, repsAtWeight, volume
}

public struct PersonalRecord: Sendable, Equatable, Codable {
    public let exerciseId: String
    public let kind: RecordKind
    public let valueKg: Double?
    public let reps: Int?
    public let weightKg: Double?
    public let previousKg: Double?

    public init(exerciseId: String, kind: RecordKind, valueKg: Double?, reps: Int?, weightKg: Double?,
                previousKg: Double?) {
        self.exerciseId = exerciseId
        self.kind = kind
        self.valueKg = valueKg
        self.reps = reps
        self.weightKg = weightKg
        self.previousKg = previousKg
    }
}

public enum RecordDetector {
    /// Records only count against existing history; a first-ever session sets bests silently.
    public static func records(for workout: Workout, previous: [String: ExerciseBests]) -> [PersonalRecord] {
        workout.entries.flatMap { entry -> [PersonalRecord] in
            guard let prior = previous[entry.exerciseId] else { return [] }
            let now = ExerciseBests(entry: entry)
            var found: [PersonalRecord] = []
            if let e1RM = now.e1RMKg, e1RM > (prior.e1RMKg ?? 0) + 0.01 {
                found.append(PersonalRecord(exerciseId: entry.exerciseId, kind: .e1RM, valueKg: e1RM, reps: nil,
                                            weightKg: nil, previousKg: prior.e1RMKg))
            }
            let repRecords = now.repsAtWeight
                .filter { key, reps in reps > (prior.repsAtWeight[key] ?? Int.max) }
                .sorted { $0.key > $1.key }
                .map { key, reps in
                    PersonalRecord(exerciseId: entry.exerciseId, kind: .repsAtWeight, valueKg: nil,
                                   reps: reps, weightKg: Double(key) / 1_000, previousKg: nil)
                }
            found.append(contentsOf: repRecords)
            if now.volumeKg > prior.volumeKg + 0.01 {
                found.append(PersonalRecord(exerciseId: entry.exerciseId, kind: .volume, valueKg: now.volumeKg,
                                            reps: nil, weightKg: nil, previousKg: prior.volumeKg))
            }
            return found
        }
    }
}
