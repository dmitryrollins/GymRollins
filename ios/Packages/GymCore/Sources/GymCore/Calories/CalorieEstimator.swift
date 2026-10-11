import Foundation

/// A workout's estimated energy use: `kcal = MET × body weight (kg) × active hours`, summed per Compendium activity.
public struct CalorieEstimate: Sendable, Equatable {
    public struct Part: Sendable, Equatable {
        public let code: String
        public let met: Double
        public let minutes: Double
        public let kcal: Double
    }

    /// Whole kcal (the sum of the parts, rounded): total energy, as the Compendium formula gives it.
    public let kcal: Int
    /// The active part, without resting energy (1 MET): `(MET − 1) × kg × hours`, what Apple Health's active energy
    /// means (it counts resting energy separately).
    public let activeKcal: Int
    /// Active time the estimate covers (paused time excluded, capped at `CalorieEstimator.maxActiveSeconds`).
    public let activeSeconds: TimeInterval
    public let bodyWeightKg: Double
    /// No usable weigh-in: `CalorieEstimator.defaultBodyWeightKg` was used.
    public let usedDefaultBodyWeight: Bool
    public let effort: EffortLevel
    /// Per Compendium code, most minutes first.
    public let parts: [Part]
    public let healthActivity: HealthActivityKind
    /// The workout was longer than `maxActiveSeconds`.
    public let wasCapped: Bool
}

/// Latest-known body weight for a date.
public struct BodyWeightSample: Sendable, Equatable {
    public let date: Date
    public let weightKg: Double

    public init(date: Date, weightKg: Double) {
        self.date = date
        self.weightKg = weightKg
    }
}

public enum BodyWeightPicker {
    /// The latest weigh-in on or before `date`, else the earliest one after it, else nil.
    public static func weightKg(at date: Date, samples: [BodyWeightSample]) -> Double? {
        let sorted = samples.sorted { $0.date < $1.date }
        return sorted.last { $0.date <= date }?.weightKg ?? sorted.first?.weightKg
    }
}

/// Pure calorie estimate from the 2024 Adult Compendium of Physical Activities (plan 15 documents every rule).
public enum CalorieEstimator {
    /// The Compendium's reference adult, used when no weigh-in exists.
    public static let defaultBodyWeightKg = 70.0
    public static let minActiveSeconds: TimeInterval = 60
    public static let maxActiveSeconds: TimeInterval = 4 * 3_600

    private struct Share {
        let activity: CalorieActivity
        /// Logged cardio minutes (nil: the entry shares the untimed pool by `units`).
        let loggedMinutes: Double?
        let units: Int
        let workingSets: [WorkoutSet]
        var minutes: Double = 0
    }

    public static func estimate(workout: Workout, exercise: (String) -> Exercise?, bodyWeightKg: Double?,
                                table: METTable) -> CalorieEstimate? {
        guard let end = workout.endedAt else { return nil }
        let raw = max(0, end.timeIntervalSince(workout.startedAt) - workout.pausedSeconds)
        guard raw >= minActiveSeconds else { return nil }
        let active = min(raw, maxActiveSeconds)
        guard let shares = allocate(shares(workout, exercise: exercise), minutes: active / 60) else { return nil }

        let effort = effort(shares)
        let weight = bodyWeightKg.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let kg = weight ?? defaultBodyWeightKg
        var byCode: [String: (met: Double, minutes: Double)] = [:]
        for share in shares where share.minutes > 0 {
            let code = share.activity.code(effort: effort)
            guard let met = table.met(for: code) else { return nil }
            byCode[code, default: (met, 0)].minutes += share.minutes
        }
        let parts = byCode.map { code, value in
            CalorieEstimate.Part(code: code, met: value.met, minutes: value.minutes,
                                 kcal: value.met * kg * value.minutes / 60)
        }.sorted { ($0.minutes, $1.code) > ($1.minutes, $0.code) }
        let activeKcal = parts.reduce(0.0) { $0 + max(0, $1.met - 1) * kg * $1.minutes / 60 }
        return CalorieEstimate(kcal: Int(parts.reduce(0) { $0 + $1.kcal }.rounded()),
                               activeKcal: Int(activeKcal.rounded()), activeSeconds: active,
                               bodyWeightKg: kg, usedDefaultBodyWeight: weight == nil, effort: effort, parts: parts,
                               healthActivity: healthActivity(shares), wasCapped: raw > maxActiveSeconds)
    }

    // MARK: Steps

    /// One share per entry with working sets; superset groups of 2 turn weights into reciprocal supersets, groups
    /// of 3+ exercises turn every non-cardio entry into circuit training.
    private static func shares(_ workout: Workout, exercise: (String) -> Exercise?) -> [Share] {
        let working = workout.entries.map { entry in (entry, WorkoutMetrics.workingSets(entry)) }
            .filter { !$0.1.isEmpty }
        var groups: [String: Set<String>] = [:]
        for (entry, _) in working {
            if let group = entry.supersetGroup { groups[group, default: []].insert(entry.exerciseId) }
        }
        return working.map { entry, sets in
            var activity = ActivityClassifier.activity(for: exercise(entry.exerciseId), sets: sets)
            let groupSize = entry.supersetGroup.flatMap { groups[$0]?.count } ?? 0
            if !activity.isCardio && groupSize >= 3 {
                activity = .circuit
            } else if groupSize == 2 && (activity == .weights || activity == .squatDeadlift) {
                activity = .supersetWeights
            }
            let logged = activity.isCardio
                ? sets.reduce(0.0) { $0 + ($1.minutes ?? $1.sec.map { Double($0) / 60 } ?? 0) } : 0
            return Share(activity: activity, loggedMinutes: logged > 0 ? logged : nil, units: sets.count,
                         workingSets: sets)
        }
    }

    /// Logged cardio time first (scaled down to fit), the rest by working-set count; nil when nothing can take time.
    private static func allocate(_ shares: [Share], minutes total: Double) -> [Share]? {
        let logged = shares.reduce(0.0) { $0 + ($1.loggedMinutes ?? 0) }
        let scale = logged > total ? total / logged : 1
        let leftover = max(0, total - logged * scale)
        let units = shares.reduce(0) { $0 + ($1.loggedMinutes == nil ? $1.units : 0) }
        guard logged > 0 || units > 0 else { return nil }
        return shares.map { share in
            var copy = share
            copy.minutes = share.loggedMinutes.map { $0 * scale }
                ?? (units > 0 ? leftover * Double(share.units) / Double(units) : 0)
            return copy
        }
    }

    private static func effort(_ shares: [Share]) -> EffortLevel {
        let rpes = shares.flatMap(\.workingSets).compactMap(EffortRule.rpe)
        if !rpes.isEmpty { return EffortRule.fromRPE(rpes.reduce(0, +) / Double(rpes.count)) }
        let strength = shares.filter { !$0.activity.isCardio }
        let sets = strength.reduce(0) { $0 + $1.units }
        guard sets > 0 else { return .moderate }
        return EffortRule.fromDensity(minutesPerSet: strength.reduce(0.0) { $0 + $1.minutes } / Double(sets))
    }

    private static func healthActivity(_ shares: [Share]) -> HealthActivityKind {
        if shares.contains(where: { !$0.activity.isCardio }) { return .strength }
        var minutes: [CardioKind: Double] = [:]
        for share in shares {
            if case .cardio(let kind) = share.activity { minutes[kind, default: 0] += share.minutes }
        }
        let top = minutes.max { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }
        return top?.key.healthActivity ?? .mixedCardio
    }
}
