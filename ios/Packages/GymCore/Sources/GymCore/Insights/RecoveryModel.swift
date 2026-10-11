import Foundation

public enum RecoveryStatus: String, Sendable, Codable {
    case fresh, recovering, fatigued

    /// fresh ≥ 90 %, recovering 50–89 %, fatigued < 50 %.
    public init(percent: Int) {
        switch percent {
        case 90...: self = .fresh
        case 50..<90: self = .recovering
        default: self = .fatigued
        }
    }
}

public struct MuscleRecovery: Equatable, Sendable, Identifiable {
    public var id: MuscleGroup { group }
    public let group: MuscleGroup
    /// 0…100, 100 = fully recovered.
    public let percent: Int
    /// 0…1 remaining fatigue (`percent` before rounding, inverted).
    public let fatigue: Double
    /// When a hard set last worked this group (primary or secondary), nil if never in the given workouts.
    public let lastTrained: Date?
    /// When the remaining fatigue reaches zero, nil if already fully recovered.
    public let recoveredAt: Date?

    public var status: RecoveryStatus { RecoveryStatus(percent: percent) }

    public init(group: MuscleGroup, percent: Int, fatigue: Double, lastTrained: Date?, recoveredAt: Date?) {
        self.group = group
        self.percent = percent
        self.fatigue = fatigue
        self.lastTrained = lastTrained
        self.recoveredAt = recoveredAt
    }
}

/// Recovery per muscle group from recent workouts. Pure and deterministic (`now` is injected).
///
/// Per workout (at `endedAt ?? startedAt`) and group, `load` = Σ set effort × role weight (primary 1, secondary
/// 0.5; see `MuscleLoads`). The session leaves fatigue `min(1, load / 6)` that decays linearly to zero over
/// `clamp(24 + 6 × load, 24, 96)` hours — about 48 h for a normal 4-set session, up to 4 days for high volume.
/// Sessions stack (sum, capped at 1). Recovery % = round(100 × (1 − fatigue)).
/// Keep in sync with `supabase/functions/_shared/insights.ts` (shared fixture `fixtures/insights.json`).
public enum RecoveryModel {
    /// Effective sets that leave a group fully fatigued right after the session.
    public static let saturationLoad = 6.0
    public static let minHours = 24.0
    public static let hoursPerSet = 6.0
    public static let maxHours = 96.0
    /// Workouts older than this can't leave fatigue (the longest recovery window).
    public static let lookback: TimeInterval = maxHours * 3_600

    public static func recoveryHours(load: Double) -> Double {
        min(max(minHours + hoursPerSet * load, minHours), maxHours)
    }

    /// Every `MuscleGroup` in declaration order. `workouts` should be finished workouts; ones after `now` are ignored.
    public static func compute(workouts: [Workout], exercise: (String) -> Exercise?, now: Date) -> [MuscleRecovery] {
        var fatigue: [MuscleGroup: Double] = [:]
        var lastTrained: [MuscleGroup: Date] = [:]
        var recoveredAt: [MuscleGroup: Date] = [:]
        for workout in workouts {
            let at = workout.endedAt ?? workout.startedAt
            guard at <= now else { continue }
            let elapsedHours = now.timeIntervalSince(at) / 3_600
            for (group, load) in MuscleLoads.of(workout, exercise: exercise) {
                lastTrained[group] = max(lastTrained[group] ?? .distantPast, at)
                let hours = recoveryHours(load: load.load)
                guard elapsedHours < hours else { continue }
                let initial = min(1, load.load / saturationLoad)
                fatigue[group, default: 0] += initial * (1 - elapsedHours / hours)
                let done = at.addingTimeInterval(hours * 3_600)
                recoveredAt[group] = max(recoveredAt[group] ?? .distantPast, done)
            }
        }
        return MuscleGroup.allCases.map { group in
            let f = min(1, fatigue[group] ?? 0)
            return MuscleRecovery(group: group, percent: Int((100 * (1 - f)).rounded()), fatigue: f,
                                  lastTrained: lastTrained[group], recoveredAt: f > 0 ? recoveredAt[group] : nil)
        }
    }

    /// Groups to suggest ("Fresh: back, biceps"): fresh, trained within `rotationDays` (so the list sticks to what
    /// the owner actually trains), not `limited`; most recovered first, then the longest since trained.
    public static func freshest(_ recoveries: [MuscleRecovery], limited: Set<MuscleGroup>, now: Date,
                                rotationDays: Int = 28, count: Int = 3) -> [MuscleGroup] {
        let since = now.addingTimeInterval(-Double(rotationDays) * 86_400)
        let order = Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.enumerated().map { ($1, $0) })
        return recoveries
            .filter { r in
                guard let last = r.lastTrained else { return false }
                return r.status == .fresh && last >= since && !limited.contains(r.group)
            }
            .sorted { a, b in
                if a.percent != b.percent { return a.percent > b.percent }
                if a.lastTrained != b.lastTrained { return (a.lastTrained ?? .distantPast) < (b.lastTrained ?? .distantPast) }
                return order[a.group, default: 0] < order[b.group, default: 0]
            }
            .prefix(count)
            .map(\.group)
    }
}
