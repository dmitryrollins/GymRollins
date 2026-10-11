import Foundation
import GymCore
import GymWatchLink
import os

/// Applies Apple Watch commands on the phone (plan 17). Workout actions become `WorkoutActivityAction`s and go through
/// `WorkoutSession.perform` — the Live Activity's path, with its stale-tap rules — so the watch never has logging logic
/// of its own. Each command id is applied once (the ledger survives relaunches).
@MainActor
final class WatchCommandHandler {
    enum Outcome: Equatable {
        case applied
        /// Didn't apply any more (stale, another workout, out-of-range values) or wasn't allowed.
        case ignored
        /// Already applied (the same command delivered twice).
        case duplicate
        /// The watch asked for the current state.
        case stateRequested
    }

    struct Hooks {
        var session: @MainActor () -> WorkoutSession?
        var exercise: @MainActor (String) -> Exercise?
        /// Apple Health is on in the app.
        var healthEnabled: @MainActor () -> Bool
        /// Starts today's workout; false when there's nothing to start.
        var startToday: @MainActor () -> Bool
        /// The watch's claim to write this workout to Health was accepted.
        var acceptClaim: @MainActor (UUID) -> Void
        /// The watch wrote this workout to Health.
        var recorded: @MainActor (UUID) -> Void
    }

    static let ledgerKey = "watchCommandLedger"
    /// How far apart the watch's copy of the rest start and the phone's may be (JSON dates round-trip exactly).
    static let restMatchTolerance: TimeInterval = 0.5
    private static let log = Logger(subsystem: "com.rollins.gymrollins", category: "watch")

    private let defaults: UserDefaults
    private let hooks: Hooks
    private var ledger: WatchCommandLedger

    init(defaults: UserDefaults, hooks: Hooks) {
        self.defaults = defaults
        self.hooks = hooks
        ledger = defaults.data(forKey: Self.ledgerKey)
            .flatMap { try? JSONDecoder().decode(WatchCommandLedger.self, from: $0) } ?? WatchCommandLedger()
    }

    func handle(_ command: WatchCommand) -> Outcome {
        guard !ledger.contains(command.id) else { return .duplicate }
        let outcome = apply(command.action)
        if case .requestState = command.action {} else { remember(command.id) }
        if outcome == .ignored {
            Self.log.notice("Watch command ignored: it no longer applies (\(String(describing: command.action), privacy: .public))")
        }
        return outcome
    }

    // MARK: Private

    private func apply(_ action: WatchAction) -> Outcome {
        switch action {
        case .requestState:
            return .stateRequested
        case .startToday:
            guard hooks.session() == nil else { return .ignored }
            return hooks.startToday() ? .applied : .ignored
        case .healthClaim(let workoutId):
            let running = hooks.session().flatMap { $0.workout.endedAt == nil && !$0.isAbandoned ? $0.workout.id : nil }
            guard WatchHealthRules.phoneAcceptsClaim(workoutId: workoutId, runningWorkoutId: running,
                                                     healthEnabled: hooks.healthEnabled()) else { return .ignored }
            hooks.acceptClaim(workoutId)
            return .applied
        case .healthRecorded(let workoutId, let average, let max):
            Self.log.info("Watch saved workout \(workoutId, privacy: .public) (avg HR \(average ?? 0), max \(max ?? 0))")
            hooks.recorded(workoutId)
            return .applied
        case .logSet, .extendRest, .skipRest, .showExercise:
            guard let session = hooks.session(), let activity = activityAction(action, session: session) else {
                return .ignored
            }
            return session.perform(activity, exercise: hooks.exercise) ? .applied : .ignored
        }
    }

    /// The Live Activity action for a workout command, nil when it can't apply (bad values, a rest other than the one
    /// the watch saw).
    private func activityAction(_ action: WatchAction, session: WorkoutSession) -> WorkoutActivityAction? {
        switch action {
        case .logSet(let workoutId, let entryId, let setId, let weight, let unit, let reps):
            guard weight.isFinite, DomainLimits.setReps.contains(reps),
                  let planned = session.entry(entryId)?.sets.first(where: { $0.id == setId }) else { return nil }
            let kg = WatchStateMapper.loggedKg(weight: weight, unit: unit, plannedKg: planned.weightKg)
            guard DomainLimits.setWeightKg.contains(kg) else { return nil }
            return .logSet(workoutId: workoutId, entryId: entryId, setId: setId, weightKg: kg, reps: reps)
        case .extendRest(let workoutId, let entryId, let startedAt, let seconds):
            guard isCurrentRest(startedAt, in: session), seconds.isFinite, seconds > 0, seconds <= 600 else { return nil }
            return .extendRest(workoutId: workoutId, entryId: entryId, seconds: seconds)
        case .skipRest(let workoutId, let entryId, let startedAt):
            guard isCurrentRest(startedAt, in: session) else { return nil }
            return .skipRest(workoutId: workoutId, entryId: entryId)
        case .showExercise(let workoutId, let fromEntryId, let direction):
            return .showExercise(workoutId: workoutId, fromEntryId: fromEntryId,
                                 step: direction == .next ? .next : .previous)
        case .startToday, .healthClaim, .healthRecorded, .requestState:
            return nil
        }
    }

    /// A queued +30s / Skip must not land on a later rest.
    private func isCurrentRest(_ startedAt: Date, in session: WorkoutSession) -> Bool {
        guard let rest = session.activeRest(at: session.currentDate) else { return false }
        return abs(rest.startedAt.timeIntervalSince(startedAt)) <= Self.restMatchTolerance
    }

    private func remember(_ id: UUID) {
        ledger = ledger.recording(id)
        do {
            defaults.set(try JSONEncoder().encode(ledger), forKey: Self.ledgerKey)
        } catch {
            Self.log.error("Saving the watch ledger failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
