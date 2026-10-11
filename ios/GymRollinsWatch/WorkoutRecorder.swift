import Foundation
import GymWatchLink
import HealthKit
import Observation
import os

/// The watch's HealthKit workout session for the phone's workout (plan 17): keeps the app running with the wrist down
/// (rest haptic), collects heart rate and active energy, and at the end saves the workout to Health — with the phone
/// exporter's external id and sync identifier — or discards it (`WatchRecorderPolicy` decides which).
///
/// HealthKit objects stay on the main actor; the completion-handler APIs are used (wrapped in continuations) so no
/// non-Sendable HealthKit object crosses an isolation boundary. Delegate callbacks copy plain values and hop back.
@MainActor
@Observable
final class WorkoutRecorder: NSObject {
    private(set) var status = WatchRecorderStatus.idle
    /// Beats per minute, latest sample.
    private(set) var heartRate: Double?
    /// A start/end is in progress (the coordinator waits for it).
    private(set) var isBusy = false
    private(set) var lastError: String?

    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var workoutName: String?
    private nonisolated static let log = Logger(subsystem: "com.rollins.gymrollins.watchkitapp", category: "workout")
    private nonisolated static let heartRateType = HKQuantityType(.heartRate)
    private nonisolated static let beatsPerMinute = HKUnit.count().unitDivided(by: .minute())

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Lifecycle

    /// Asks for Health access while the app is on screen (a session the phone wakes in the background can't ask).
    /// HealthKit only shows the sheet once; later calls return straight away.
    func prepare() async {
        guard Self.isAvailable else { return }
        do { try await requestAuthorization() } catch {
            Self.log.error("Health authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Starts a session (from the phone's `startWatchApp`, or when the app sees a running phone workout).
    func start(workoutId: UUID?, name: String?, startDate: Date) async {
        guard Self.isAvailable, !status.isRunning, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await requestAuthorization()
            let configuration = Self.configuration()
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            workoutName = name
            session.startActivity(with: startDate)
            try await beginCollection(builder, at: startDate)
            status = WatchRecorderStatus(isRunning: true, workoutId: workoutId, startedAt: startDate)
            lastError = nil
        } catch {
            Self.log.error("Workout session start failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't start the workout on your watch."
            reset()
        }
    }

    /// A session HealthKit kept running while the app was terminated (`handleActiveWorkoutRecovery`).
    func recover() async {
        guard !status.isRunning, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard let session = await recoverSession() else { return }
        let builder = session.associatedWorkoutBuilder()
        session.delegate = self
        builder.delegate = self
        self.session = session
        self.builder = builder
        // The phone workout it belonged to isn't known any more: the next state attaches it (or ends it unsaved).
        // Its grace for a phone state counts from now, not from its original start.
        status = WatchRecorderStatus(isRunning: true, workoutId: nil, startedAt: builder.startDate ?? Date(),
                                     unattachedSince: Date())
    }

    func attach(workoutId: UUID, name: String) {
        guard status.isRunning else { return }
        workoutName = name
        status = WatchRecorderStatus(isRunning: true, workoutId: workoutId, startedAt: status.startedAt,
                                     claimSent: false, isPaused: status.isPaused)
    }

    func updateName(_ name: String) { workoutName = name }

    func markClaimSent() {
        status = WatchRecorderStatus(isRunning: status.isRunning, workoutId: status.workoutId,
                                     startedAt: status.startedAt, claimSent: true, isPaused: status.isPaused,
                                     unattachedSince: status.unattachedSince)
    }

    func pause() {
        session?.pause()
        setPaused(true)
    }

    func resume() {
        session?.resume()
        setPaused(false)
    }

    /// Ends the session at `endDate` (clamped to its start). Saved: the Health workout, with average/max heart rate
    /// returned for the phone; discarded: nil.
    func end(save: Bool, endDate: Date) async -> (average: Double?, max: Double?)? {
        guard status.isRunning, let session, let builder, !isBusy else { return nil }
        isBusy = true
        defer {
            isBusy = false
            reset()
        }
        let end = max(endDate, status.startedAt ?? endDate)
        session.stopActivity(with: end)
        session.end()
        do {
            try await endCollection(builder, at: end)
            guard save, let workoutId = status.workoutId else {
                builder.discardWorkout()
                return nil
            }
            try await addMetadata(builder, metadata(workoutId: workoutId))
            let stats = builder.statistics(for: Self.heartRateType)
            try await finish(builder)
            return (stats?.averageQuantity()?.doubleValue(for: Self.beatsPerMinute),
                    stats?.maximumQuantity()?.doubleValue(for: Self.beatsPerMinute))
        } catch {
            Self.log.error("Workout session end failed: \(error.localizedDescription, privacy: .public)")
            builder.discardWorkout()
            return nil
        }
    }

    // MARK: Private

    private static func configuration() -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        return configuration
    }

    /// The same keys the phone's exporter writes, so Health (and the phone) treat it as the one GymRollins workout.
    private func metadata(workoutId: UUID) -> [String: Any] {
        var metadata: [String: Any] = [
            HKMetadataKeyExternalUUID: workoutId.uuidString,
            WatchHealthRules.exportMarkerKey: true,
            WatchHealthRules.writerKey: WatchHealthRules.watchWriter,
            HKMetadataKeySyncIdentifier: WatchHealthRules.syncIdentifier(workoutId: workoutId),
            HKMetadataKeySyncVersion: NSNumber(value: Int64(Date().timeIntervalSince1970 * 1_000)),
            HKMetadataKeyIndoorWorkout: true
        ]
        if let workoutName { metadata[WatchHealthRules.workoutNameKey] = workoutName }
        return metadata
    }

    private func setPaused(_ paused: Bool) {
        status = WatchRecorderStatus(isRunning: status.isRunning, workoutId: status.workoutId,
                                     startedAt: status.startedAt, claimSent: status.claimSent, isPaused: paused,
                                     unattachedSince: status.unattachedSince)
    }

    private func reset() {
        session = nil
        builder = nil
        workoutName = nil
        heartRate = nil
        status = .idle
    }

    fileprivate func sessionEndedElsewhere() {
        // Ended from Control Center / a system stop: nothing more to collect; unsaved.
        guard status.isRunning, !isBusy else { return }
        builder?.discardWorkout()
        reset()
    }

    fileprivate func setHeartRate(_ bpm: Double) { heartRate = bpm }

    // MARK: HealthKit calls (completion handlers, main actor)

    private func requestAuthorization() async throws {
        let share: Set<HKSampleType> = [HKObjectType.workoutType(), HKQuantityType(.activeEnergyBurned)]
        let read: Set<HKObjectType> = [Self.heartRateType, HKQuantityType(.activeEnergyBurned)]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: share, read: read) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func beginCollection(_ builder: HKLiveWorkoutBuilder, at date: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.beginCollection(withStart: date) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func endCollection(_ builder: HKLiveWorkoutBuilder, at date: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.endCollection(withEnd: date) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func addMetadata(_ builder: HKLiveWorkoutBuilder, _ metadata: [String: Any]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.addMetadata(metadata) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func finish(_ builder: HKLiveWorkoutBuilder) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.finishWorkout { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func recoverSession() async -> HKWorkoutSession? {
        await withCheckedContinuation { (continuation: CheckedContinuation<HKWorkoutSession?, Never>) in
            store.recoverActiveWorkoutSession { session, error in
                if let error { Self.log.error("Recovery failed: \(error.localizedDescription, privacy: .public)") }
                continuation.resume(returning: session)
            }
        }
    }
}

extension WorkoutRecorder: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended || toState == .stopped else { return }
        Task { @MainActor in self.sessionEndedElsewhere() }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Self.log.error("Workout session failed: \(error.localizedDescription, privacy: .public)")
    }
}

extension WorkoutRecorder: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard collectedTypes.contains(Self.heartRateType),
              let bpm = workoutBuilder.statistics(for: Self.heartRateType)?.mostRecentQuantity()?
                .doubleValue(for: Self.beatsPerMinute) else { return }
        Task { @MainActor in self.setHeartRate(bpm) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
