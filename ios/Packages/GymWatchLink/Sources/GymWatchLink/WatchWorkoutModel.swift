import Foundation
import Observation

/// Sends commands to the phone: `WatchConnectivityLink` on the watch, a fake in tests.
@MainActor
public protocol WatchCommandSending: AnyObject {
    var isReachable: Bool { get }
    /// Sends now when the phone is reachable, otherwise queues it for later delivery — unless `reachableOnly`, then
    /// nothing is sent. Returns whether it was sent or queued.
    @discardableResult
    func send(_ command: WatchCommand, reachableOnly: Bool) -> Bool
}

/// What the watch shows and what its buttons do. The phone owns the workout: every action is a command naming the
/// workout, set or rest it was made for, and the screen changes when the phone's next state arrives.
@MainActor
@Observable
public final class WatchWorkoutModel {
    public static let extraRest: TimeInterval = 30
    /// A Log set the phone hasn't answered within this long may be tapped again.
    public static let pendingTimeout: TimeInterval = 5
    public static let openPhoneNotice = "Open GymRollins on iPhone"

    public private(set) var state: WatchState?
    /// A one-line message for the user (e.g. the phone isn't reachable), nil when there's nothing to say.
    public private(set) var notice: String?
    /// Crown edits of the shown set, dropped when another set is shown.
    private var edit: (setId: UUID, weight: Double?, reps: Int?)?
    private var pending: (setId: UUID, since: Date)?
    /// Clears `pending` once `pendingTimeout` passes without an answer, so the screen stops showing "Logging…" by
    /// itself (`isLogging` alone depends on the time, which nothing observes).
    @ObservationIgnored private(set) var pendingExpiry: Task<Void, Never>?
    /// The rest whose end already buzzed (`startedAt`).
    private var buzzedRest: Date?

    @ObservationIgnored private let sender: WatchCommandSending
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @MainActor (TimeInterval) async throws -> Void

    /// `sleep` waits that many seconds (injected by tests to fire the "Logging…" timeout on demand).
    public init(sender: WatchCommandSending, now: @escaping () -> Date = Date.init,
                sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.sender = sender
        self.now = now
        self.sleep = sleep
    }

    // MARK: State

    public var workout: WatchWorkout? { state?.workout }
    public var next: WatchNextSet? { workout?.next }

    /// A newer state from the phone (an older one — out-of-order delivery — is ignored). Returns whether it was taken.
    @discardableResult
    public func receive(_ newState: WatchState) -> Bool {
        if let state, newState.sentAt < state.sentAt { return false }
        state = newState
        if let edit, edit.setId != newState.workout?.next?.setId { self.edit = nil }
        // Any answer from the phone ends the wait: the set was logged (another set is shown) or the tap didn't apply
        // (the phone sends its state back). A repeated tap is harmless — the phone ignores a set that isn't next.
        clearPending()
        if newState.workout != nil { notice = nil }
        return true
    }

    /// The weight Log set would send, in the set's unit.
    public var weight: Double? {
        guard let next else { return nil }
        return edit?.setId == next.setId ? edit?.weight ?? next.weight : next.weight
    }

    public var reps: Int? {
        guard let next else { return nil }
        return edit?.setId == next.setId ? edit?.reps ?? next.reps : next.reps
    }

    public var isLogging: Bool {
        guard let pending, pending.setId == next?.setId else { return false }
        return now().timeIntervalSince(pending.since) < Self.pendingTimeout
    }

    public func stepWeight(by steps: Int) {
        guard let next, let weight else { return }
        let stepped = CrownStepper.weight(weight, steppedBy: steps, grid: next.grid)
        edit = (next.setId, stepped, edit?.setId == next.setId ? edit?.reps : nil)
    }

    public func stepReps(by steps: Int) {
        guard let next, let reps else { return }
        let stepped = CrownStepper.reps(reps, steppedBy: steps)
        edit = (next.setId, edit?.setId == next.setId ? edit?.weight : nil, stepped)
    }

    // MARK: Actions

    public func logSet() {
        guard let workout, let next, next.canLog, let weight, let reps, !isLogging else { return }
        let sent = send(.logSet(workoutId: workout.id, entryId: next.entryId, setId: next.setId, weight: weight,
                                unit: next.grid.unit, reps: reps))
        if sent { startPending(setId: next.setId) }
    }

    public func addRest() {
        guard let workout, let rest = runningRest else { return }
        send(.extendRest(workoutId: workout.id, entryId: next?.entryId, restStartedAt: rest.startedAt,
                         seconds: Self.extraRest))
    }

    public func skipRest() {
        guard let workout, let rest = runningRest else { return }
        send(.skipRest(workoutId: workout.id, entryId: next?.entryId, restStartedAt: rest.startedAt))
    }

    public func canShow(_ direction: WatchDirection) -> Bool {
        guard let workout, workout.next != nil else { return false }
        return direction == .next ? workout.hasNext : workout.hasPrevious
    }

    public func show(_ direction: WatchDirection) {
        guard let workout, let next, canShow(direction) else { return }
        send(.showExercise(workoutId: workout.id, fromEntryId: next.entryId, direction: direction))
    }

    /// Asks the phone to start today's workout; needs the phone right now (nothing is queued).
    public func startToday() {
        guard sender.isReachable, send(.startToday, reachableOnly: true) else {
            notice = Self.openPhoneNotice
            return
        }
        notice = nil
    }

    public func requestState() {
        send(.requestState, reachableOnly: true)
    }

    public func sendHealthClaim(workoutId: UUID) {
        send(.healthClaim(workoutId: workoutId))
    }

    public func sendHealthRecorded(workoutId: UUID, averageHeartRate: Double?, maxHeartRate: Double?) {
        send(.healthRecorded(workoutId: workoutId, averageHeartRate: averageHeartRate, maxHeartRate: maxHeartRate))
    }

    public func clearNotice() { notice = nil }

    // MARK: Clocks

    /// The phone's rest, while it hasn't run out.
    public var runningRest: WatchRest? {
        guard let rest = workout?.rest, rest.endsAt > now() else { return nil }
        return rest
    }

    public func restRemaining(at date: Date) -> TimeInterval? {
        guard let rest = workout?.rest, rest.endsAt > date else { return nil }
        return rest.endsAt.timeIntervalSince(date)
    }

    /// True once per rest, the first time it's asked at or after the rest's end (plays the haptic). A rest the phone
    /// skipped or extended is no longer the state's rest, so it never buzzes early.
    public func takeRestFinished(at date: Date) -> Bool {
        guard let rest = workout?.rest, date >= rest.endsAt, buzzedRest != rest.startedAt else { return false }
        buzzedRest = rest.startedAt
        return true
    }

    /// Active workout time (pauses excluded), frozen while paused.
    public func elapsed(at date: Date) -> TimeInterval? {
        guard let workout else { return nil }
        let end = workout.pausedAt ?? date
        return max(0, end.timeIntervalSince(workout.startedAt) - workout.pausedSeconds)
    }

    // MARK: Private

    private func startPending(setId: UUID) {
        let since = now()
        pending = (setId, since)
        pendingExpiry?.cancel()
        pendingExpiry = Task { [weak self, sleep] in
            do { try await sleep(Self.pendingTimeout) } catch { return } // cancelled: the phone answered
            guard let self, !Task.isCancelled, let pending = self.pending, pending.setId == setId,
                  pending.since == since else { return }
            self.pending = nil
            self.pendingExpiry = nil
        }
    }

    private func clearPending() {
        pending = nil
        pendingExpiry?.cancel()
        pendingExpiry = nil
    }

    @discardableResult
    private func send(_ action: WatchAction, reachableOnly: Bool = false) -> Bool {
        sender.send(WatchCommand(issuedAt: now(), action: action), reachableOnly: reachableOnly)
    }
}
