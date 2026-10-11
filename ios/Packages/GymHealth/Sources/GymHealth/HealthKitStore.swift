#if os(iOS) || os(watchOS)
import Foundation
import GymCore
import GymWatchLink
import HealthKit

/// The real `HealthStore`: HealthKit on iPhone (and, later, Apple Watch). Every sample GymRollins writes carries
/// `HKMetadataKeyExternalUUID` = the app's id, which is how updates and deletes find it.
public actor HealthKitStore: HealthStore {
    public nonisolated let isAvailable: Bool
    private let store: HKHealthStore?
    private let bundleId: String?

    // Shared with the Apple Watch app, which writes the same metadata on the workouts it records (plan 17).
    static let workoutNameKey = WatchHealthRules.workoutNameKey
    static let exportMarkerKey = WatchHealthRules.exportMarkerKey

    public init(bundleId: String? = Bundle.main.bundleIdentifier) {
        let available = HKHealthStore.isHealthDataAvailable()
        isAvailable = available
        store = available ? HKHealthStore() : nil
        self.bundleId = bundleId
    }

    private static let bodyMass = HKQuantityType(.bodyMass)
    private static let bodyFat = HKQuantityType(.bodyFatPercentage)
    private static let energy = HKQuantityType(.activeEnergyBurned)
    private static let workout = HKObjectType.workoutType()

    private static func sampleType(_ type: HealthDataType) -> HKSampleType {
        switch type {
        case .workouts: workout
        case .activeEnergy: energy
        case .bodyMass: bodyMass
        case .bodyFat: bodyFat
        }
    }

    private func healthStore() throws -> HKHealthStore {
        guard let store else { throw HKError(.errorHealthDataUnavailable) }
        return store
    }

    // MARK: Authorization

    public func requestAuthorization() async throws {
        let share = Set(HealthDataType.allCases.map(Self.sampleType))
        // Workouts are read only to find the Apple Watch's copy of a GymRollins workout (plan 17).
        let read: Set<HKObjectType> = [Self.bodyMass, Self.bodyFat, Self.workout]
        try await healthStore().requestAuthorization(toShare: share, read: read)
    }

    public func permissions() async -> HealthPermissions {
        guard let store else { return .notDetermined }
        return HealthPermissions(write: Dictionary(uniqueKeysWithValues: HealthDataType.allCases.map { type in
            let status: HealthPermission = switch store.authorizationStatus(for: Self.sampleType(type)) {
            case .sharingAuthorized: .authorized
            case .sharingDenied: .denied
            default: .notDetermined
            }
            return (type, status)
        }))
    }

    // MARK: Workouts

    public func save(workout item: HealthWorkout) async throws {
        let store = try healthStore()
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = Self.activityType(item.activity)
        configuration.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        try await builder.beginCollection(at: item.start)
        // Optional parts only when their type is allowed: HealthKit rejects a whole batch for one denied sample.
        if let kcal = item.kcal, kcal > 0, allowed(Self.energy, in: store) {
            let sample = HKQuantitySample(type: Self.energy, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                                          start: item.start, end: item.end,
                                          metadata: marker(item.externalId, kind: "energy"))
            try await builder.addSamples([sample])
        }
        var workoutMetadata = marker(item.externalId, kind: "workout")
        workoutMetadata[Self.workoutNameKey] = item.name
        workoutMetadata[HKMetadataKeyIndoorWorkout] = true
        try await builder.addMetadata(workoutMetadata)
        if item.pausedSeconds > 0 {
            // Only the total pause is known: record it as one pause right before the end, so Health's duration
            // matches the app's active time.
            let pausedAt = max(item.start, item.end.addingTimeInterval(-item.pausedSeconds))
            try await builder.addWorkoutEvents([
                HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: pausedAt, duration: 0), metadata: nil),
                HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: item.end, duration: 0), metadata: nil),
            ])
        }
        try await builder.endCollection(at: item.end)
        _ = try await builder.finishWorkout()
    }

    public func deleteWorkout(externalId: UUID, withEnergy: Bool) async throws {
        let store = try healthStore()
        let predicate = Self.externalIdPredicate(externalId)
        try await delete(main: Self.workout, optional: Self.energy, required: withEnergy, predicate: predicate,
                         in: store)
    }

    public func workoutCopies(externalId: UUID) async throws -> [HealthWorkoutCopy] {
        let store = try healthStore()
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(Self.externalIdPredicate(externalId))],
                                                 sortDescriptors: [])
        return try await descriptor.result(for: store).map {
            HealthWorkoutCopy(externalId: externalId, writtenByThisApp: !Self.isWatchRecording($0))
        }
    }

    /// Deletes the phone's workout objects one by one (never by a predicate that could also match the watch's
    /// recording, whose HealthKit source may be this app's), plus the phone's energy sample (the watch's live energy
    /// samples don't carry the external id).
    public func deleteOwnWorkout(externalId: UUID, withEnergy: Bool) async throws {
        let store = try healthStore()
        guard allowed(Self.workout, in: store), !withEnergy || allowed(Self.energy, in: store) else {
            throw HKError(.errorAuthorizationDenied)
        }
        let predicate = Self.externalIdPredicate(externalId)
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [])
        let phoneCopies = try await descriptor.result(for: store).filter { !Self.isWatchRecording($0) }
        if !phoneCopies.isEmpty { try await store.delete(phoneCopies) }
        if allowed(Self.energy, in: store) { _ = try await store.deleteObjects(of: Self.energy, predicate: predicate) }
    }

    private static func isWatchRecording(_ workout: HKWorkout) -> Bool {
        WatchHealthRules.isWatchRecording(writer: workout.metadata?[WatchHealthRules.writerKey] as? String,
                                          deviceModel: workout.device?.model)
    }

    // MARK: Weigh-ins

    public func save(weighIn: HealthWeighIn) async throws {
        var samples = [HKQuantitySample(type: Self.bodyMass,
                                        quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: weighIn.weightKg),
                                        start: weighIn.date, end: weighIn.date,
                                        metadata: marker(weighIn.externalId, kind: "bodyMass"))]
        let store = try healthStore()
        if let fat = weighIn.bodyFatPct, allowed(Self.bodyFat, in: store) {
            samples.append(HKQuantitySample(type: Self.bodyFat,
                                            quantity: HKQuantity(unit: .percent(), doubleValue: fat / 100),
                                            start: weighIn.date, end: weighIn.date,
                                            metadata: marker(weighIn.externalId, kind: "bodyFat")))
        }
        try await store.save(samples)
    }

    public func deleteWeighIn(externalId: UUID, withBodyFat: Bool) async throws {
        let store = try healthStore()
        let predicate = Self.externalIdPredicate(externalId)
        try await delete(main: Self.bodyMass, optional: Self.bodyFat, required: withBodyFat, predicate: predicate,
                         in: store)
    }

    // MARK: Import

    public func bodyChanges(since start: Date, anchor: Data?) async throws -> HealthBodyChanges {
        let store = try healthStore()
        let dates = HKQuery.predicateForSamples(withStart: start, end: nil)
        let previous = try anchor.flatMap {
            try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
        }
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.quantitySample(type: Self.bodyMass, predicate: dates),
                         .quantitySample(type: Self.bodyFat, predicate: dates)],
            anchor: previous)
        let result = try await descriptor.result(for: store)
        let added = result.addedSamples.compactMap(sample)
        let newAnchor = try NSKeyedArchiver.archivedData(withRootObject: result.newAnchor, requiringSecureCoding: true)
        return HealthBodyChanges(added: added, deleted: result.deletedObjects.map(\.uuid), anchor: newAnchor)
    }

    private func sample(_ quantity: HKQuantitySample) -> HealthBodySample? {
        let own = quantity.sourceRevision.source.bundleIdentifier == bundleId
            || quantity.metadata?[Self.exportMarkerKey] != nil
        let name = quantity.sourceRevision.source.name
        switch quantity.quantityType {
        case Self.bodyMass:
            return HealthBodySample(uuid: quantity.uuid, kind: .bodyMass,
                                    value: quantity.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                                    date: quantity.startDate, fromThisApp: own, sourceName: name)
        case Self.bodyFat:
            return HealthBodySample(uuid: quantity.uuid, kind: .bodyFat,
                                    value: quantity.quantity.doubleValue(for: .percent()) * 100,
                                    date: quantity.startDate, fromThisApp: own, sourceName: name)
        default:
            return nil
        }
    }

    // MARK: Helpers

    /// The main type must be writable, and the optional one too when it was exported (`required`); otherwise this
    /// throws and the caller keeps the export to retry once access is back.
    private func delete(main: HKObjectType, optional: HKObjectType, required: Bool, predicate: NSPredicate,
                        in store: HKHealthStore) async throws {
        guard allowed(main, in: store), !required || allowed(optional, in: store) else {
            throw HKError(.errorAuthorizationDenied)
        }
        _ = try await store.deleteObjects(of: main, predicate: predicate)
        if allowed(optional, in: store) { _ = try await store.deleteObjects(of: optional, predicate: predicate) }
    }

    private func allowed(_ type: HKObjectType, in store: HKHealthStore) -> Bool {
        store.authorizationStatus(for: type) == .sharingAuthorized
    }

    /// External id (how updates/deletes find it) plus a per-type sync identifier: if two devices export the same
    /// workout or weigh-in, HealthKit keeps one copy (the higher sync version) instead of two.
    private func marker(_ externalId: UUID, kind: String) -> [String: Any] {
        [HKMetadataKeyExternalUUID: externalId.uuidString, Self.exportMarkerKey: true,
         WatchHealthRules.writerKey: WatchHealthRules.phoneWriter,
         HKMetadataKeySyncIdentifier: "gymrollins.\(kind).\(externalId.uuidString)",
         HKMetadataKeySyncVersion: NSNumber(value: Int64(Date().timeIntervalSince1970 * 1_000))]
    }

    private static func externalIdPredicate(_ id: UUID) -> NSPredicate {
        HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [id.uuidString])
    }

    static func activityType(_ kind: HealthActivityKind) -> HKWorkoutActivityType {
        switch kind {
        case .strength: .traditionalStrengthTraining
        case .running: .running
        case .walking: .walking
        case .cycling: .cycling
        case .elliptical: .elliptical
        case .stairClimbing: .stairClimbing
        case .jumpRope: .jumpRope
        case .rowing: .rowing
        case .hiit: .highIntensityIntervalTraining
        case .mixedCardio: .mixedCardio
        }
    }
}
#endif
