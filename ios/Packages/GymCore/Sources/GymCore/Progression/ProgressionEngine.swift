import Foundation

/// One past session of an exercise: working sets only.
public struct SessionResult: Sendable, Equatable {
    public let date: Date
    public let weightKg: Double
    public let reps: [Int]
    public let secs: [Int]
    /// Reps in reserve per set, parallel to `reps` (nil where the set wasn't rated; empty when none were).
    public let rir: [Double?]

    public init(date: Date, weightKg: Double, reps: [Int], secs: [Int] = [], rir: [Double?] = []) {
        self.date = date
        self.weightKg = weightKg
        self.reps = reps
        self.secs = secs
        self.rir = rir
    }
}

public struct ProgressionTarget: Sendable, Equatable {
    public let sets: Int
    /// Top of the rep range.
    public let reps: Int
    /// Bottom of the rep range (double progression); nil means `reps`.
    public let repsMin: Int?
    public let sec: Int?
    public let weightKg: Double
    public let incKg: Double
    /// When the plan's `weightKg` was last set by the user or Claude; used to gate the `.planned` override.
    public let weightSetAt: Date?

    public init(sets: Int, reps: Int, repsMin: Int? = nil, sec: Int? = nil, weightKg: Double, incKg: Double,
                weightSetAt: Date? = nil) {
        self.sets = sets
        self.reps = reps
        self.repsMin = repsMin
        self.sec = sec
        self.weightKg = weightKg
        self.incKg = incKg
        self.weightSetAt = weightSetAt
    }

    var low: Int { repsMin ?? reps }
}

public enum SuggestionReason: String, Sendable, Codable {
    case firstSession, planned, noChange, keepGoing, topOfRange, success, doubleJump, deload, addTime
    /// Every set reached the rep range and was rated easy (`ProgressionEngine.feltEasy`): +inc before the top.
    case feltEasy
}

public struct Suggestion: Sendable, Equatable {
    public let weightKg: Double
    public let reps: Int
    public let sec: Int?
    public let reason: SuggestionReason
}

public struct ProgressionEngine: Sendable {
    public let rounder: LoadRounder
    public let deloadPct: Double
    public let missesBeforeDeload: Int

    public init(rounder: LoadRounder, deloadPct: Double = 0.05, missesBeforeDeload: Int = 2) {
        self.rounder = rounder
        self.deloadPct = deloadPct
        self.missesBeforeDeload = missesBeforeDeload
    }

    /// - Parameters:
    ///   - mode: the exercise's mode; the policy is first made compatible with it (`ProgressionPolicy.effective`),
    ///     so a timed exercise progresses by time and cardio keeps its duration target.
    ///   - history: past sessions of this exercise, newest first.
    public func suggest(policy requested: ProgressionPolicy, mode: ExerciseMode = .reps, target: ProgressionTarget,
                        history: [SessionResult]) -> Suggestion {
        let policy = requested.effective(for: mode)
        guard let last = history.first else {
            return Suggestion(weightKg: rounder.nearest(target.weightKg), reps: target.low, sec: target.sec,
                              reason: .firstSession)
        }
        // A weight planned (by the owner or an applied Claude proposal) after the last session wins in either
        // direction — a planned reduction must not be overridden by progression from the heavier history.
        if policy != .off, let weightSetAt = target.weightSetAt, weightSetAt > last.date,
           abs(target.weightKg - last.weightKg) > 0.01 {
            return Suggestion(weightKg: rounder.nearest(target.weightKg), reps: target.low, sec: target.sec,
                              reason: .planned)
        }
        switch policy {
        case .off:
            return Suggestion(weightKg: last.weightKg, reps: target.reps, sec: target.sec, reason: .noChange)
        case .time:
            return suggestTime(target: target, history: history)
        case .linear, .double, .greyskull:
            return suggestLoad(policy: policy, target: target, history: history, last: last)
        }
    }

    private func suggestTime(target: ProgressionTarget, history: [SessionResult]) -> Suggestion {
        var goal = target.sec ?? 30
        var newestHit = false
        for session in history.reversed() {
            let hit = session.secs.count >= target.sets && session.secs.allSatisfy { $0 >= goal }
            newestHit = hit
            if hit { goal = (session.secs.min() ?? goal) + 5 }
        }
        let weight = history.first?.weightKg ?? 0
        return newestHit
            ? Suggestion(weightKg: weight, reps: target.reps, sec: goal, reason: .addTime)
            : Suggestion(weightKg: weight, reps: target.reps, sec: goal, reason: .keepGoing)
    }

    private func suggestLoad(policy: ProgressionPolicy, target: ProgressionTarget, history: [SessionResult],
                             last: SessionResult) -> Suggestion {
        if deloadDue(target: target, history: history) {
            let weight = rounder.down(last.weightKg * (1 - deloadPct))
            return Suggestion(weightKg: weight, reps: target.low, sec: target.sec, reason: .deload)
        }
        let hitTop = last.reps.count >= target.sets && last.reps.allSatisfy { $0 >= target.reps }
        if policy == .greyskull, hitTop, let amrap = last.reps.last, amrap >= target.reps * 2 {
            let weight = rounder.nearest(last.weightKg + 2 * target.incKg)
            return Suggestion(weightKg: weight, reps: target.reps, sec: target.sec, reason: .doubleJump)
        }
        if hitTop {
            let weight = rounder.nearest(last.weightKg + target.incKg)
            return policy == .double
                ? Suggestion(weightKg: weight, reps: target.low, sec: target.sec, reason: .topOfRange)
                : Suggestion(weightKg: weight, reps: target.reps, sec: target.sec, reason: .success)
        }
        if let weight = feltEasy(target: target, last: last) {
            return Suggestion(weightKg: weight, reps: policy == .double ? target.low : target.reps, sec: target.sec,
                              reason: .feltEasy)
        }
        return Suggestion(weightKg: last.weightKg, reps: target.reps, sec: target.sec, reason: .keepGoing)
    }

    /// Logged reps in reserve can only bring an increase forward, never cut the load. The early increase needs every
    /// working set at or above the bottom of the rep range, an average RIR of at least 3 over the rated sets, and no
    /// set taken to failure (RIR 0) short of the top. The step is at most `incKg` (rounded down to a loadable weight);
    /// when no loadable weight fits in one increment it holds. Returns nil (no early increase) without any RIR.
    private func feltEasy(target: ProgressionTarget, last: SessionResult) -> Double? {
        let rated = last.rir.compactMap { $0 }
        guard !rated.isEmpty, rated.reduce(0, +) / Double(rated.count) >= 3,
              last.reps.count >= target.sets, last.reps.allSatisfy({ $0 >= target.low }) else { return nil }
        let failedShort = zip(last.reps, last.rir).contains { reps, rir in reps < target.reps && (rir ?? 1) <= 0 }
        let weight = rounder.down(last.weightKg + target.incKg)
        return !failedShort && weight > last.weightKg + 0.01 ? weight : nil
    }

    private func deloadDue(target: ProgressionTarget, history: [SessionResult]) -> Bool {
        let recent = history.prefix(missesBeforeDeload)
        guard recent.count == missesBeforeDeload, let weight = recent.first?.weightKg else { return false }
        return recent.allSatisfy { session in
            abs(session.weightKg - weight) < 0.01
                && (session.reps.count < target.sets || session.reps.contains { $0 < target.low })
        }
    }
}
