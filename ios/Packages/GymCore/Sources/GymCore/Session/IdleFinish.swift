import Foundation

/// Finishing long after the last set (the owner forgot to tap Finish) would count the idle time as training: a
/// 20-minute workout saved as 1:46 and ~500 kcal, sent to Apple Health too. When the last completed set is that
/// far back, the finish flow offers ending at the last set (plus one rest) instead of now.
public enum IdleFinish {
    /// Idle time that counts as "forgot to finish". Rest tops out at 15 min (`DomainLimits.restSec`) and a normal
    /// gap between sets — rest, a walk to the next station, a sip of water — is a few minutes; 15 minutes without
    /// logging anything is past any of that, yet catches a forgotten workout before it adds much (~70 kcal).
    public static let minimumIdle: TimeInterval = 15 * 60
    /// With a long rest setting the threshold is rest + this, so sitting out a full rest never prompts.
    public static let restMargin: TimeInterval = 5 * 60
    /// The suggested end adds at least this after the last set (rest off or very short).
    public static let minimumRest: TimeInterval = 60

    /// The end to offer instead of `now`: the last completed set plus one rest (≥ `minimumRest`), or nil when the
    /// owner isn't idle long enough or nothing was logged (then they decide; nothing is offered).
    ///
    /// Idle time is measured to the pause when the clock is paused (a pause stops the clock already), and the
    /// completed pauses are subtracted from it, since they may have fallen after the last set. The result is never
    /// before the workout's start nor after the clock stopped.
    public static func suggestedEnd(completedAt: [Date], clock: WorkoutClock, restSeconds: TimeInterval,
                                    now: Date) -> Date? {
        guard let last = completedAt.max() else { return nil }
        let stopped = clock.pausedAt ?? now
        let idle = stopped.timeIntervalSince(last) - clock.pausedSeconds
        guard idle > max(minimumIdle, restSeconds + restMargin) else { return nil }
        let end = last.addingTimeInterval(max(minimumRest, restSeconds))
        return min(max(end, clock.startedAt), stopped)
    }
}
