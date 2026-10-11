import Foundation

/// In-memory Health with HealthKit's semantics (only this app's own data can be deleted, reads are anchored), for
/// package tests and the DEBUG `-fakeHealth` launch flag.
public actor FakeHealthStore: HealthStore {
    public struct Failure: Error, Equatable { public let message: String }

    public nonisolated let isAvailable: Bool
    /// This app's (the phone exporter's) workouts.
    public private(set) var workouts: [HealthWorkout] = []
    /// Workouts another source wrote with GymRollins' metadata: the Apple Watch app's, synced to this Health store.
    public private(set) var watchWorkouts: [HealthWorkout] = []
    /// `workoutCopies` calls.
    public private(set) var workoutLookups = 0
    /// Every `deleteOwnWorkout`, in order (also in `deletedWorkoutIds`).
    public private(set) var ownDeletedWorkoutIds: [UUID] = []
    public private(set) var weighIns: [HealthWeighIn] = []
    public private(set) var authorizationRequests = 0
    public private(set) var saveCount = 0
    /// Every `deleteWorkout` that got past the gate, in order.
    public private(set) var deletedWorkoutIds: [UUID] = []
    private var grantOnRequest: [HealthDataType: HealthPermission]
    private var current: HealthPermissions = .notDetermined
    private var failSaves = false
    /// Every body sample in "Health" (other apps' and ours) with the change sequence it was added at.
    private var samples: [(seq: Int, sample: HealthBodySample)] = []
    private var deletions: [(seq: Int, uuid: UUID)] = []
    /// Our exported weigh-ins' sample ids, by external id.
    private var ownSamples: [UUID: [UUID]] = [:]
    private var seq = 0
    private var gated = false
    private var gateDeletes = false
    private var gateReads = true
    private var failReads = false
    private var failOptionalDeletes = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(isAvailable: Bool = true, grantOnRequest: [HealthDataType: HealthPermission]? = nil,
                seed: [HealthBodySample] = []) {
        self.isAvailable = isAvailable
        self.grantOnRequest = grantOnRequest
            ?? Dictionary(uniqueKeysWithValues: HealthDataType.allCases.map { ($0, .authorized) })
        for sample in seed {
            seq += 1
            samples.append((seq, sample))
        }
    }

    /// Three Withings weigh-ins (one with body fat) before `now`, for UI tests.
    public static func uiTestSeed(now: Date) -> [HealthBodySample] {
        let day: TimeInterval = 86_400
        return [
            HealthBodySample(kind: .bodyMass, value: 81.0, date: now.addingTimeInterval(-15 * day), sourceName: "Withings"),
            HealthBodySample(kind: .bodyMass, value: 81.3, date: now.addingTimeInterval(-8 * day), sourceName: "Withings"),
            HealthBodySample(kind: .bodyFat, value: 15.2, date: now.addingTimeInterval(-8 * day), sourceName: "Withings"),
            HealthBodySample(kind: .bodyMass, value: 81.6, date: now.addingTimeInterval(-1 * day), sourceName: "Withings"),
        ]
    }

    // MARK: Test controls

    public func setFailSaves(_ fail: Bool) { failSaves = fail }

    /// Reads (body changes, workout lookups) throw while on.
    public func setFailReads(_ fail: Bool) { failReads = fail }

    /// The Apple Watch app saved its workout (it syncs to this store under another source).
    public func addWatchWorkout(_ workout: HealthWorkout) { watchWorkouts.append(workout) }

    /// Deletes remove the main record, then throw as if deleting the energy / body fat sample failed.
    public func setFailOptionalDeletes(_ fail: Bool) { failOptionalDeletes = fail }

    /// `readsToo: false` lets workout lookups through (to park a run at its delete instead).
    public func setGate(_ on: Bool, deletesToo: Bool = false, readsToo: Bool = true) {
        gated = on
        gateDeletes = on && deletesToo
        gateReads = !on || readsToo
        guard !on else { return }
        let parked = waiters
        waiters = []
        parked.forEach { $0.resume() }
    }

    public var parkedCount: Int { waiters.count }

    private func passGate() async {
        guard gated else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func setPermissions(_ permissions: [HealthDataType: HealthPermission]) {
        current = HealthPermissions(write: permissions)
    }

    /// Another app (a scale) writes a sample.
    public func addExternal(_ sample: HealthBodySample) {
        seq += 1
        samples.append((seq, sample))
    }

    /// The user deletes a sample in the Health app.
    public func deleteExternal(_ uuid: UUID) {
        remove([uuid])
    }

    public func bodySamples() -> [HealthBodySample] { samples.map(\.sample) }

    // MARK: HealthStore

    public func requestAuthorization() async throws {
        authorizationRequests += 1
        // Like HealthKit: asking again never changes a decision already made.
        current = HealthPermissions(write: Dictionary(uniqueKeysWithValues: HealthDataType.allCases.map { type in
            let now = current.permission(type)
            return (type, now == .notDetermined ? grantOnRequest[type] ?? .notDetermined : now)
        }))
    }

    public func permissions() async -> HealthPermissions { current }

    public func save(workout: HealthWorkout) async throws {
        await passGate()
        try check(.workouts)
        saveCount += 1
        // Like HealthKitStore: the energy sample is only written when that type is allowed.
        let energyAllowed = current.permission(.activeEnergy) == .authorized
        workouts.append(energyAllowed ? workout : workout.withoutEnergy)
        // Worst case for the shared sync identifier: a newer version replaces the watch's copy.
        watchWorkouts.removeAll { $0.externalId == workout.externalId }
    }

    public func workoutCopies(externalId: UUID) async throws -> [HealthWorkoutCopy] {
        if gateReads { await passGate() }
        workoutLookups += 1
        if failReads { throw Failure(message: "Reading failed") }
        return workouts.filter { $0.externalId == externalId }
            .map { HealthWorkoutCopy(externalId: $0.externalId, writtenByThisApp: true) }
            + watchWorkouts.filter { $0.externalId == externalId }
            .map { HealthWorkoutCopy(externalId: $0.externalId, writtenByThisApp: false) }
    }

    public func deleteOwnWorkout(externalId: UUID, withEnergy: Bool) async throws {
        if gateDeletes { await passGate() }
        ownDeletedWorkoutIds.append(externalId)
        deletedWorkoutIds.append(externalId)
        guard current.permission(.workouts) == .authorized,
              !withEnergy || current.permission(.activeEnergy) == .authorized else {
            throw Failure(message: "Not authorized")
        }
        workouts.removeAll { $0.externalId == externalId }
        if failOptionalDeletes && withEnergy { throw Failure(message: "Deleting energy failed") }
    }

    public func deleteWorkout(externalId: UUID, withEnergy: Bool) async throws {
        if gateDeletes { await passGate() }
        deletedWorkoutIds.append(externalId)
        guard current.permission(.workouts) == .authorized,
              !withEnergy || current.permission(.activeEnergy) == .authorized else {
            throw Failure(message: "Not authorized")
        }
        workouts.removeAll { $0.externalId == externalId }
        // Like HealthKit with a companion watch app sharing the iOS app's source: an external-id delete hits it too.
        watchWorkouts.removeAll { $0.externalId == externalId }
        if failOptionalDeletes && withEnergy { throw Failure(message: "Deleting energy failed") }
    }

    public func save(weighIn: HealthWeighIn) async throws {
        await passGate()
        try check(.bodyMass)
        saveCount += 1
        weighIns.append(weighIn)
        var ids = [UUID()]
        addOwn(HealthBodySample(uuid: ids[0], kind: .bodyMass, value: weighIn.weightKg, date: weighIn.date))
        if let fat = weighIn.bodyFatPct, current.permission(.bodyFat) == .authorized {
            ids.append(UUID())
            addOwn(HealthBodySample(uuid: ids[1], kind: .bodyFat, value: fat, date: weighIn.date))
        }
        ownSamples[weighIn.externalId, default: []] += ids
    }

    public func deleteWeighIn(externalId: UUID, withBodyFat: Bool) async throws {
        if gateDeletes { await passGate() }
        guard current.permission(.bodyMass) == .authorized,
              !withBodyFat || current.permission(.bodyFat) == .authorized else {
            throw Failure(message: "Not authorized")
        }
        weighIns.removeAll { $0.externalId == externalId }
        remove(ownSamples[externalId] ?? [])
        ownSamples[externalId] = nil
    }

    public func bodyChanges(since start: Date, anchor: Data?) async throws -> HealthBodyChanges {
        await passGate()
        if failReads { throw Failure(message: "Reading failed") }
        let from = anchor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let added = samples.filter { $0.seq > from && $0.sample.date >= start }.map(\.sample)
        let deleted = anchor == nil ? [] : deletions.filter { $0.seq > from }.map(\.uuid)
        return HealthBodyChanges(added: added, deleted: deleted, anchor: Data("\(seq)".utf8))
    }

    // MARK: Private

    private func check(_ type: HealthDataType) throws {
        if failSaves { throw Failure(message: "Saving failed") }
        guard current.permission(type) == .authorized else { throw Failure(message: "Not authorized") }
    }

    private func addOwn(_ sample: HealthBodySample) {
        seq += 1
        samples.append((seq, HealthBodySample(uuid: sample.uuid, kind: sample.kind, value: sample.value,
                                              date: sample.date, fromThisApp: true, sourceName: "GymRollins")))
    }

    private func remove(_ uuids: [UUID]) {
        let set = Set(uuids)
        guard samples.contains(where: { set.contains($0.sample.uuid) }) else { return }
        samples.removeAll { set.contains($0.sample.uuid) }
        for uuid in uuids {
            seq += 1
            deletions.append((seq, uuid))
        }
    }
}
