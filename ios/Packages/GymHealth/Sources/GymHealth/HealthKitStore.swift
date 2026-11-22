#if os(iOS) || os(watchOS)
import Foundation
import GymCore
import GymWatchLink
import HealthKit
import os

/// The real `HealthStore`: HealthKit on iPhone (and, later, Apple Watch). Every sample GymRollins writes carries
/// `HKMetadataKeyExternalUUID` = the app's id, which is how updates and deletes find it.
public actor HealthKitStore: HealthStore {
    public nonisolated let isAvailable: Bool
    private let store: HKHealthStore?
    private let bundleId: String?

    // Shared with the Apple Watch app, which writes the same metadata on the workouts it records (plan 17).
    static let workoutNameKey = WatchHealthRules.workoutNameKey
    static let exportMarkerKey = WatchHealthRules.exportMarkerKey
    /// Starts the sync identifier of every workout or weigh-in GymRollins writes (the watch app uses the same).
    static let syncIdentifierPrefix = "gymrollins."

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
        var share = Set(HealthDataType.allCases.map(Self.sampleType))
        // A workout's effort rating is written too (plan 40). It isn't a `HealthDataType`: that enum is the export's
        // write list, and `HealthPermissions.summary` reads it.
        share.insert(Self.effortScore)
        // Workouts are read to find the Apple Watch's copy of a GymRollins workout (plan 17) and, with the activity
        // types, to bring in what other apps record (plan 39); the effort scores to show a workout's effort (plan 40).
        // The system only asks for types never asked.
        var read: Set<HKObjectType> = [Self.bodyMass, Self.bodyFat, Self.workout]
        read.formUnion(Self.activityReadTypes)
        read.formUnion(Self.effortReadTypes)
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
        return HealthBodyChanges(added: added, deleted: result.deletedObjects.filter { !isOwnDeletion($0) }.map(\.uuid),
                                           anchor: newAnchor)
    }

    /// GymRollins' own workout or weigh-in, re-exported or deleted by the app: Health reports that as a deletion too,
    /// but there is no imported row for it, so it is dropped here instead of waiting in an unmatched list.
    private func isOwnDeletion(_ object: HKDeletedObject) -> Bool {
        (object.metadata?[HKMetadataKeySyncIdentifier] as? String)?.hasPrefix(Self.syncIdentifierPrefix) == true
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

    // MARK: Activity (plan 39)

    private static let steps = HKQuantityType(.stepCount)
    private static let heartRate = HKQuantityType(.heartRate)
    private static let exerciseTime = HKQuantityType(.appleExerciseTime)
    /// Resting energy: with the active energy, a workout's total (Apple Fitness's "Total").
    private static let basalEnergy = HKQuantityType(.basalEnergyBurned)
    private static let cyclingCadence = HKQuantityType(.cyclingCadence)
    /// Walking/running, cycling and swimming: a workout has the one that fits its kind.
    private static let distances = [HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling),
                                    HKQuantityType(.distanceSwimming)]
    /// Cycling power first (a ride from a power meter or GymKit equipment), else running power (a run on an Apple
    /// Watch).
    private static let powers = [HKQuantityType(.cyclingPower), HKQuantityType(.runningPower)]

    /// What the activity import reads: step count, active and resting energy, heart rate, distance, power and cycling
    /// cadence (each workout's statistics), exercise time and Activity summaries. Never in `HealthDataType`, the
    /// write list.
    static var activityReadTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [steps, heartRate, exerciseTime, energy, basalEnergy, cyclingCadence,
                                        HKObjectType.activitySummaryType()]
        for quantity in distances + powers { types.insert(quantity) }
        return types
    }

    public func outsideWorkoutChanges(since start: Date, anchor: Data?) async throws -> HealthOutsideWorkoutChanges {
        let store = try healthStore()
        let previous = try anchor.flatMap {
            try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
        }
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: nil))], anchor: previous)
        let result = try await descriptor.result(for: store)
        let newAnchor = try NSKeyedArchiver.archivedData(withRootObject: result.newAnchor, requiringSecureCoding: true)
        return HealthOutsideWorkoutChanges(added: result.addedSamples.map(outsideWorkout),
                                           deleted: result.deletedObjects.filter { !isOwnDeletion($0) }.map(\.uuid),
                                           anchor: newAnchor)
    }

    /// The outside workout as its statistics have it. A value the workout has no statistic for (no power meter, no
    /// resting energy) stays nil.
    private func outsideWorkout(_ workout: HKWorkout) -> HealthOutsideWorkout {
        let perMinute = HKUnit.count().unitDivided(by: .minute())
        let heart = workout.statistics(for: Self.heartRate)
        let distance = Self.distances.lazy
            .compactMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }.first
        let power = Self.powers.lazy
            .compactMap { workout.statistics(for: $0)?.averageQuantity()?.doubleValue(for: .watt()) }.first
        let active = workout.statistics(for: Self.energy)?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let basal = workout.statistics(for: Self.basalEnergy)?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let activity = HealthActivity(
            id: workout.uuid, kind: Self.kindSlug(workout.workoutActivityType), startedAt: workout.startDate,
            endedAt: workout.endDate, durationS: workout.duration, kcal: active,
            totalKcal: HealthActivity.totalKcal(active: active, basal: basal), distanceM: distance,
            avgHr: Self.whole(heart?.averageQuantity()?.doubleValue(for: perMinute)),
            maxHr: Self.whole(heart?.maximumQuantity()?.doubleValue(for: perMinute)),
            avgPowerW: Self.whole(power),
            avgCadenceRpm: Self.whole(workout.statistics(for: Self.cyclingCadence)?.averageQuantity()?
                .doubleValue(for: perMinute)),
            sourceName: workout.sourceRevision.source.name,
            fromWatch: workout.sourceRevision.productType?.hasPrefix("Watch") == true
                || workout.device?.model == "Watch")
        let external = (workout.metadata?[HKMetadataKeyExternalUUID] as? String).flatMap(UUID.init(uuidString:))
        return HealthOutsideWorkout(activity: activity, externalId: external, writtenByGymRollins: isOwn(workout))
    }

    /// Rounded to a whole number; nil for nil, NaN, infinity or a value no `Int` holds.
    private static func whole(_ value: Double?) -> Int? {
        value.flatMap { Int(exactly: $0.rounded()) }
    }

    /// Written by GymRollins: the export metadata (the phone's and the watch app's), or this app's or the watch app's
    /// bundle as the source.
    private func isOwn(_ workout: HKWorkout) -> Bool {
        if workout.metadata?[Self.exportMarkerKey] != nil || workout.metadata?[WatchHealthRules.writerKey] != nil {
            return true
        }
        guard let bundleId else { return false }
        let source = workout.sourceRevision.source.bundleIdentifier
        return source == bundleId || source == "\(bundleId).watchkitapp"
    }

    /// Steps from the merged daily statistics (never summed samples: those double count iPhone + Watch), move,
    /// exercise and stand from the Activity summary. Stand is nil on a day whose summary has no stand goal (no watch).
    public func activityDays(from start: Date, through end: Date, calendar: Calendar) async throws -> [ActivityDay] {
        let store = try healthStore()
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        guard first <= last, let after = calendar.date(byAdding: .day, value: 1, to: last) else { return [] }
        let stepsQuery = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: Self.steps,
                                       predicate: HKQuery.predicateForSamples(withStart: first, end: after)),
            options: .cumulativeSum, anchorDate: first, intervalComponents: DateComponents(day: 1))
        var steps: [String: Int] = [:]
        for statistics in try await stepsQuery.result(for: store).statistics() {
            guard let sum = statistics.sumQuantity() else { continue }
            steps[ActivityDay.key(for: statistics.startDate, calendar: calendar)] =
                Int(sum.doubleValue(for: .count()).rounded())
        }
        var from = calendar.dateComponents([.era, .year, .month, .day], from: first)
        var through = calendar.dateComponents([.era, .year, .month, .day], from: last)
        from.calendar = calendar
        through.calendar = calendar
        let summaries = try await HKActivitySummaryQueryDescriptor(
            predicate: HKQuery.predicate(forActivitySummariesBetweenStart: from, end: through)).result(for: store)
        var rings: [String: HKActivitySummary] = [:]
        for summary in summaries {
            guard let date = calendar.date(from: summary.dateComponents(for: calendar)) else { continue }
            rings[ActivityDay.key(for: date, calendar: calendar)] = summary
        }
        return Set(steps.keys).union(rings.keys).sorted().map { key in
            let ring = rings[key]
            let standGoal = ring?.standHoursGoal?.doubleValue(for: .count()) ?? 0
            return ActivityDay(day: key, steps: steps[key] ?? 0,
                               moveKcal: ring?.activeEnergyBurned.doubleValue(for: .kilocalorie()) ?? 0,
                               exerciseMin: Int((ring?.appleExerciseTime.doubleValue(for: .minute()) ?? 0).rounded()),
                               standH: standGoal > 0
                                   ? ring.map { Int($0.appleStandHours.doubleValue(for: .count()).rounded()) } : nil)
        }
    }

    /// The `OutsideWorkoutKind` slug of a HealthKit workout type (plan 39); `other` for a type GymRollins doesn't name.
    public static func kindSlug(_ type: HKWorkoutActivityType) -> String {
        let kind: OutsideWorkoutKind = switch type {
        case .walking, .wheelchairWalkPace: .walking
        case .running, .wheelchairRunPace: .running
        case .cycling, .handCycling: .cycling
        case .highIntensityIntervalTraining: .hiit
        case .yoga: .yoga
        case .swimming: .swimming
        case .traditionalStrengthTraining: .traditionalStrength
        case .functionalStrengthTraining: .functionalStrength
        case .elliptical: .elliptical
        case .rowing: .rowing
        case .hiking: .hiking
        case .cardioDance, .socialDance, .barre: .dance
        case .coreTraining: .core
        case .pilates: .pilates
        case .cooldown, .preparationAndRecovery: .cooldown
        case .stairClimbing, .stairs, .stepTraining: .stairs
        case .jumpRope: .jumpRope
        case .mixedCardio: .mixedCardio
        case .crossTraining: .crossTraining
        case .flexibility: .flexibility
        case .mindAndBody, .taiChi: .mindAndBody
        case .tennis: .tennis
        case .soccer: .soccer
        case .basketball: .basketball
        case .boxing: .boxing
        case .kickboxing: .kickboxing
        case .martialArts: .martialArts
        case .climbing: .climbing
        case .downhillSkiing, .crossCountrySkiing: .skiing
        case .snowboarding: .snowboarding
        case .golf: .golf
        default: .other
        }
        return kind.rawValue
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
         HKMetadataKeySyncIdentifier: "\(Self.syncIdentifierPrefix)\(kind).\(externalId.uuidString)",
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

// MARK: Measurements (plan 40)

extension HealthKitStore {
    /// A person's rating of a workout (1–10), made in Fitness or here: GymRollins reads it and writes its own.
    private static let effortScore = HKQuantityType(.workoutEffortScore)
    /// The Apple Watch's own estimate of a workout's effort: read only.
    private static let estimatedEffortScore = HKQuantityType(.estimatedWorkoutEffortScore)
    private static let log = Logger(subsystem: "com.rollins.gymrollins", category: "health")

    /// Both effort scores, read for a workout's effort; the rating is also written (`requestAuthorization`).
    static var effortReadTypes: Set<HKObjectType> { [effortScore, estimatedEffortScore] }

    public func workoutMeasurements(externalId: UUID, start: Date, end: Date) async throws -> WorkoutMeasurements {
        let store = try healthStore()
        let copy = try await gymRollinsCopy(externalId, in: store)
        let heartRate = try await heartRateReadings(from: start, through: end, in: store)
        let postEnd = end.addingTimeInterval(WorkoutMeasuredRules.postWindow)
        let post = try await heartRateReadings(from: end, through: postEnd, in: store)
        guard let copy else {
            return WorkoutMeasurements(recordedBy: nil, duration: nil, activeKcal: nil, totalKcal: nil,
                                       heartRate: heartRate, postWorkout: post, effort: nil)
        }
        let effort = await effort(of: copy, in: store)
        // The phone's copy holds the app's own estimate (decision 8): its time and calories are never read back.
        guard Self.isWatchRecording(copy) else {
            return WorkoutMeasurements(recordedBy: .phone, duration: nil, activeKcal: nil, totalKcal: nil,
                                       heartRate: heartRate, postWorkout: post, effort: effort)
        }
        let active = copy.statistics(for: Self.energy)?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let resting = await restingKcal(during: copy, in: store)
        return WorkoutMeasurements(recordedBy: .watch, duration: copy.duration, activeKcal: active,
                                   totalKcal: HealthActivity.totalKcal(active: active, basal: resting),
                                   heartRate: heartRate, postWorkout: post, effort: effort)
    }

    /// Saves the new rating and relates it to the copy Health shows (the watch's first), and only then removes
    /// GymRollins' earlier ones (`writeRating`).
    public func rateEffort(externalId: UUID, score: Int) async throws {
        let store = try healthStore()
        guard Effort.range.contains(score) else { throw HKError(.errorInvalidArgument) }
        guard allowed(Self.effortScore, in: store) else { throw HKError(.errorAuthorizationDenied) }
        guard let copy = try await gymRollinsCopy(externalId, in: store) else { throw HKError(.errorNoData) }
        let rating = HKQuantitySample(type: Self.effortScore,
                                      quantity: HKQuantity(unit: .appleEffortScore(), doubleValue: Double(score)),
                                      start: copy.startDate, end: copy.endDate,
                                      metadata: marker(externalId, kind: "effort"))
        try await Self.writeRating(
            save: { try await store.save(rating) },
            relate: { _ = try await store.relateWorkoutEffortSample(rating, with: copy, activity: nil) },
            deleteSaved: { try await store.delete(rating) },
            deleteEarlier: { try await self.deleteOwnEffort(externalId, in: store, except: rating.uuid) })
    }

    /// `rateEffort`'s order, public for its test. A failed save leaves the previous rating. A rating saved but not
    /// related is deleted again, so no orphan stays, and the rating fails. Once it's related Health shows it, so a
    /// failed removal of GymRollins' earlier rating is logged, not a failure ("Couldn't save to Apple Health" would be
    /// wrong): that one stays beside it until the next rating or a Clear removes it.
    public static func writeRating(save: @Sendable () async throws -> Void, relate: @Sendable () async throws -> Void,
                                   deleteSaved: @Sendable () async throws -> Void,
                                   deleteEarlier: @Sendable () async throws -> Void) async throws {
        try await save()
        do {
            try await relate()
        } catch {
            do {
                try await deleteSaved()
            } catch let cleanup {
                log.error("Health effort cleanup failed: \(cleanup.localizedDescription, privacy: .public)")
            }
            throw error
        }
        do {
            try await deleteEarlier()
        } catch {
            let reason = error.localizedDescription
            log.error("Health effort: removing the earlier rating failed: \(reason, privacy: .public)")
        }
    }

    public func clearEffort(externalId: UUID) async throws {
        let store = try healthStore()
        guard allowed(Self.effortScore, in: store) else { throw HKError(.errorAuthorizationDenied) }
        try await deleteOwnEffort(externalId, in: store)
    }

    /// HealthKit's request status for the effort types: `.unnecessary` once a request with them finished.
    public func effortTypesAsked() async -> Bool {
        guard let store else { return false }
        do {
            let status = try await store.statusForAuthorizationRequest(toShare: [Self.effortScore],
                                                                       read: Self.effortReadTypes)
            return status == .unnecessary
        } catch {
            Self.log.error("Health effort permission check failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// A workout effort sample as an `Effort`: a rating (`workoutEffortScore`) or the Apple Watch's estimate
    /// (`estimatedWorkoutEffortScore`). Nil for any other type, or a score outside 1–10.
    public static func effort(from sample: HKQuantitySample) -> Effort? {
        let estimated: Bool
        switch sample.quantityType {
        case effortScore: estimated = false
        case estimatedEffortScore: estimated = true
        default: return nil
        }
        let score = sample.quantity.doubleValue(for: .appleEffortScore()).rounded()
        return Int(exactly: score).flatMap { Effort(score: $0, estimated: estimated) }
    }

    /// The GymRollins copy of a workout: the watch app's recording when Health has one, else the phone's. Both carry
    /// the workout's id; plan 17 keeps one, but there can be two for a while after a late watch confirmation.
    private func gymRollinsCopy(_ externalId: UUID, in store: HKHealthStore) async throws -> HKWorkout? {
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(Self.externalIdPredicate(externalId))],
                                                 sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)])
        let copies = try await descriptor.result(for: store)
        return copies.first(where: Self.isWatchRecording) ?? copies.first
    }

    /// Every heart-rate value from `start` through `end`, whatever recorded it (decision 9). An Apple Watch workout
    /// can store a series of values in one sample, so each value comes with its own date; samples are matched by
    /// overlap and their values by date.
    private func heartRateReadings(from start: Date, through end: Date,
                                   in store: HKHealthStore) async throws -> [HeartRateReading] {
        let span = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKQuantitySeriesSampleQueryDescriptor(
            predicate: .quantitySample(type: Self.heartRate, predicate: span), options: .orderByQuantitySampleStartDate)
        let perMinute = HKUnit.count().unitDivided(by: .minute())
        var readings: [HeartRateReading] = []
        for try await value in descriptor.results(for: store) {
            let date = value.dateInterval.start
            guard date >= start, date <= end else { continue }
            readings.append(HeartRateReading(date: date, bpm: value.quantity.doubleValue(for: perMinute)))
        }
        return readings
    }

    /// The resting energy during the watch copy: its own statistic, else Health's merged total for its span (the watch
    /// app doesn't ask to write resting energy, so its copy may carry none while the Apple Watch recorded it). A
    /// failed read leaves the total out, not the whole read (logged).
    private func restingKcal(during copy: HKWorkout, in store: HKHealthStore) async -> Double? {
        if let own = copy.statistics(for: Self.basalEnergy)?.sumQuantity() {
            return own.doubleValue(for: .kilocalorie())
        }
        let span = HKQuery.predicateForSamples(withStart: copy.startDate, end: copy.endDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: Self.basalEnergy, predicate: span), options: .cumulativeSum)
        do {
            return try await descriptor.result(for: store)?.sumQuantity()?.doubleValue(for: .kilocalorie())
        } catch let error as HKError where error.code == .errorNoData {
            return nil
        } catch {
            Self.log.error("Health resting energy read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The effort Health shows for the copy: its most relevant related sample, a rating before the Watch's estimate.
    /// A failed read leaves the effort out, not the whole read (logged).
    private func effort(of copy: HKWorkout, in store: HKHealthStore) async -> Effort? {
        let descriptor = HKWorkoutEffortRelationshipQueryDescriptor(
            predicate: HKQuery.predicateForObject(with: copy.uuid), anchor: nil, option: .mostRelevant)
        do {
            let efforts = try await descriptor.result(for: store).relationships
                .filter { $0.workout.uuid == copy.uuid }
                .flatMap { $0.samples ?? [] }
                .compactMap { ($0 as? HKQuantitySample).flatMap(Self.effort(from:)) }
            return efforts.first { !$0.estimated } ?? efforts.first
        } catch {
            Self.log.error("Health effort read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Only this app's samples can be deleted, and only ours carry the workout's id: Fitness' rating stays. Deleting
    /// the sample ends its relation to the workout. `except` keeps the rating just saved.
    private func deleteOwnEffort(_ externalId: UUID, in store: HKHealthStore, except kept: UUID? = nil) async throws {
        var predicate = Self.externalIdPredicate(externalId)
        if let kept {
            let notKept = NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObject(with: kept))
            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, notKept])
        }
        _ = try await store.deleteObjects(of: Self.effortScore, predicate: predicate)
    }
}
#endif
