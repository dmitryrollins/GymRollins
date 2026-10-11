import Foundation

/// What the watch's workout session (HKWorkoutSession) is doing, as far as the policy needs to know.
public struct WatchRecorderStatus: Equatable, Sendable {
    public let isRunning: Bool
    /// The phone workout it records; nil right after the phone woke the watch app (`startWatchApp`), before the first
    /// state arrived.
    public let workoutId: UUID?
    public let startedAt: Date?
    /// The Health claim for `workoutId` went out.
    public let claimSent: Bool
    public let isPaused: Bool
    /// When an unattached session began waiting for its phone workout, if not at `startedAt`: a session HealthKit
    /// recovered after the app was terminated waits from the recovery, not from its (older) start.
    public let unattachedSince: Date?

    public init(isRunning: Bool, workoutId: UUID? = nil, startedAt: Date? = nil, claimSent: Bool = false,
                isPaused: Bool = false, unattachedSince: Date? = nil) {
        self.isRunning = isRunning
        self.workoutId = workoutId
        self.startedAt = startedAt
        self.claimSent = claimSent
        self.isPaused = isPaused
        self.unattachedSince = unattachedSince
    }

    /// Where the orphan grace counts from.
    var waitingSince: Date? { unattachedSince ?? startedAt }

    public static let idle = WatchRecorderStatus(isRunning: false)
}

/// The next thing the watch's workout session should do for a phone state (plan 17). Pure, so the rules are tested on
/// the Mac; `WorkoutRecorder` (watch app) carries them out with HealthKit.
public enum WatchRecorderPolicy {
    /// A session the phone woke with no workout to attach to ends (unsaved) once the phone says this long after its
    /// start that nothing runs.
    public static let orphanGrace: TimeInterval = 10
    /// How long after the grace ends an unattached session is looked at again (`recheckDelay`).
    public static let recheckMargin: TimeInterval = 1
    /// The session starts no earlier than this before now (a workout started long ago on the phone still gets heart
    /// rate from now on; Health's workout starts where the watch joined).
    public static let maxBackdate: TimeInterval = 4 * 3_600

    public enum Step: Equatable, Sendable {
        case none
        /// Start a session for this phone workout.
        case start(workoutId: UUID, startDate: Date)
        /// The running session (woken by the phone) belongs to this workout.
        case attach(workoutId: UUID)
        /// Ask the phone to let this watch write the Health workout.
        case claim(workoutId: UUID)
        /// Mirror the phone's pause.
        case pause, resume
        /// End the session, saving it to Health or discarding it.
        case end(save: Bool, endDate: Date)
    }

    /// `state` is nil while no phone state has arrived yet (e.g. the phone woke this app and the link never delivered):
    /// a session it woke then ends, unsaved, once the grace has passed.
    public static func step(state: WatchState?, recorder: WatchRecorderStatus, now: Date) -> Step {
        guard let state else { return orphanStep(recorder: recorder, now: now) }
        guard let workout = state.workout else { return stepWithoutWorkout(state: state, recorder: recorder, now: now) }
        guard recorder.isRunning else {
            let start = max(workout.startedAt, now.addingTimeInterval(-maxBackdate))
            return .start(workoutId: workout.id, startDate: min(start, now))
        }
        guard let recording = recorder.workoutId else {
            // A session woken for (or recovered from) this workout started after it did; an older one is left over
            // from something else and must not lend its heart rate/energy to this workout.
            let started = recorder.startedAt ?? now
            return started >= workout.startedAt.addingTimeInterval(-orphanGrace)
                ? .attach(workoutId: workout.id) : .end(save: false, endDate: now)
        }
        guard recording == workout.id else {
            // The phone moved on to another workout: close this one as the phone says it ended.
            return endStep(for: recording, state: state, now: now)
        }
        if !recorder.claimSent && state.healthEnabled { return .claim(workoutId: workout.id) }
        let phonePaused = workout.pausedAt != nil
        if phonePaused != recorder.isPaused { return phonePaused ? .pause : .resume }
        return .none
    }

    /// When the app should run `step` again without a new state: while a session has no phone workout, until the
    /// grace has passed (then soon again, in case the recorder was busy). Nil when no re-check is needed.
    public static func recheckDelay(recorder: WatchRecorderStatus, now: Date) -> TimeInterval? {
        guard recorder.isRunning, recorder.workoutId == nil else { return nil }
        let waiting = recorder.waitingSince ?? now
        return max(0, orphanGrace - now.timeIntervalSince(waiting)) + recheckMargin
    }

    /// The name the running session records under, from an accepted state of its own workout only (never another
    /// workout's — the phone may already have moved on while this one is being closed).
    public static func recordingName(state: WatchState, recorder: WatchRecorderStatus) -> String? {
        guard recorder.isRunning, let recording = recorder.workoutId, let workout = state.workout,
              workout.id == recording else { return nil }
        return workout.name
    }

    private static func stepWithoutWorkout(state: WatchState, recorder: WatchRecorderStatus, now: Date) -> Step {
        guard recorder.isRunning else { return .none }
        guard let recording = recorder.workoutId else { return orphanStep(recorder: recorder, now: now) }
        return endStep(for: recording, state: state, now: now)
    }

    /// A session with no phone workout to attach to: ended unsaved after a wall-clock grace (the app re-checks after
    /// it; states only come on changes, or never). One already attached is left to the phone's next state.
    private static func orphanStep(recorder: WatchRecorderStatus, now: Date) -> Step {
        guard recorder.isRunning, recorder.workoutId == nil else { return .none }
        let waiting = recorder.waitingSince ?? now
        return now.timeIntervalSince(waiting) >= orphanGrace ? .end(save: false, endDate: now) : .none
    }

    private static func endStep(for workoutId: UUID, state: WatchState, now: Date) -> Step {
        guard let ended = state.lastEnded, ended.workoutId == workoutId else {
            // The phone no longer knows it (e.g. its data was reset): nothing to save.
            return .end(save: false, endDate: now)
        }
        let save = WatchHealthRules.watchShouldSave(workoutId: workoutId, ended: ended, now: now)
        return .end(save: save, endDate: ended.finished ? ended.endedAt : now)
    }
}
