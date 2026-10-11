import Foundation
import GymWatchLink
import Observation
import WatchKit

/// Wires the watch app together (plan 17): WatchConnectivity → `WatchWorkoutModel` (what the screens show), the
/// HealthKit session (`WorkoutRecorder`, driven by `WatchRecorderPolicy`), and the rest-over haptic.
@MainActor
@Observable
final class WatchAppModel {
    let workout: WatchWorkoutModel
    let recorder = WorkoutRecorder()
    @ObservationIgnored private let link: WatchConnectivityLink
    @ObservationIgnored private var hapticTask: Task<Void, Never>?
    @ObservationIgnored private var recheckTask: Task<Void, Never>?
    /// The app is in the foreground (a session can only be started then, unless the phone woke it for one).
    @ObservationIgnored var isActive = true {
        didSet { if isActive && !oldValue { drive() } }
    }
    /// A rest that ended more than this long before the watch heard of it doesn't buzz.
    static let lateHapticLimit: TimeInterval = 5

    init() {
        let link = WatchConnectivityLink()
        self.link = link
        workout = WatchWorkoutModel(sender: link)
        link.onState = { [weak self] state in self?.received(state) }
        link.onActivated = { [weak self] in self?.workout.requestState() }
        link.onReachabilityChange = { [weak self] reachable in if reachable { self?.workout.requestState() } }
        link.activate()
    }

    var isPhoneReachable: Bool { link.isReachable }

    /// The phone started a workout and woke this app for it (`HKHealthStore.startWatchApp`).
    func startedFromPhone() {
        Task {
            let running = workout.workout
            await recorder.start(workoutId: running?.id, name: running?.name, startDate: running?.startedAt ?? Date())
            drive()
            recheckUnattached()
        }
    }

    /// A session without its phone workout yet is re-checked after the grace period even if no state arrives — or
    /// none ever did (`WatchRecorderPolicy` then ends it unsaved) — and again until it's attached or ended, in case a
    /// state arrives late or the recorder was busy.
    private func recheckUnattached() {
        guard recheckTask == nil,
              let delay = WatchRecorderPolicy.recheckDelay(recorder: recorder.status, now: Date()) else { return }
        recheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.recheckTask = nil
            self.drive()
            self.recheckUnattached()
        }
    }

    func recoverWorkout() {
        Task {
            await recorder.recover()
            drive()
            recheckUnattached()
        }
    }

    // MARK: Private

    private func received(_ state: WatchState) {
        guard workout.receive(state) else { return } // older than what's shown: out-of-order delivery
        if let name = WatchRecorderPolicy.recordingName(state: state, recorder: recorder.status) {
            recorder.updateName(name)
        }
        scheduleRestHaptic()
        drive()
    }

    /// Takes the recorder one step toward what the phone's state asks for, then looks again.
    private func drive() {
        guard !recorder.isBusy else { return }
        // No phone state yet (the link may never deliver): the policy still ends an orphan session after the grace.
        let state = workout.state
        let step = WatchRecorderPolicy.step(state: state, recorder: recorder.status, now: Date())
        switch step {
        case .none:
            return
        case .start(let workoutId, let startDate):
            guard isActive else { return } // HealthKit only starts a session from the foreground
            start(workoutId: workoutId, name: state?.workout?.name, startDate: startDate)
        case .attach(let workoutId):
            recorder.attach(workoutId: workoutId, name: state?.workout?.name ?? "")
            drive()
        case .claim(let workoutId):
            workout.sendHealthClaim(workoutId: workoutId)
            recorder.markClaimSent()
        case .pause:
            recorder.pause()
        case .resume:
            recorder.resume()
        case .end(let save, let endDate):
            end(save: save, endDate: endDate)
        }
    }

    private func start(workoutId: UUID, name: String?, startDate: Date) {
        Task {
            await recorder.start(workoutId: workoutId, name: name, startDate: startDate)
            if recorder.status.isRunning { drive() }
        }
    }

    /// Ends the session; a saved one tells the phone (which then never exports its own copy).
    private func end(save: Bool, endDate: Date) {
        let workoutId = recorder.status.workoutId
        Task {
            let heartRate = await recorder.end(save: save, endDate: endDate)
            if let workoutId, let heartRate {
                workout.sendHealthRecorded(workoutId: workoutId, averageHeartRate: heartRate.average,
                                           maxHeartRate: heartRate.max)
            }
            drive() // a new phone workout may be waiting
        }
    }

    /// Buzzes when the phone's rest runs out. The workout session keeps the app running with the wrist down, so a
    /// sleeping task is enough; a rest skipped or extended meanwhile is a new state and reschedules.
    private func scheduleRestHaptic() {
        hapticTask?.cancel()
        guard let rest = workout.workout?.rest else { return }
        let delay = rest.endsAt.timeIntervalSinceNow
        guard delay > -Self.lateHapticLimit else { return } // ended long ago (the watch was away): no late buzz
        hapticTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, self.workout.takeRestFinished(at: Date()) else { return }
            WKInterfaceDevice.current().play(.notification)
        }
    }
}
