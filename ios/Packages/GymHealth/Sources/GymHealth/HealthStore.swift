import Foundation
import GymCore

/// The Health data types GymRollins writes (and, for body mass / body fat, reads).
public enum HealthDataType: String, CaseIterable, Sendable, Codable {
    case workouts, activeEnergy, bodyMass, bodyFat

    public var title: String {
        switch self {
        case .workouts: "Workouts"
        case .activeEnergy: "Active energy"
        case .bodyMass: "Weight"
        case .bodyFat: "Body fat %"
        }
    }
}

/// Write permission for one type. HealthKit never tells an app whether it may *read*, only whether it may write.
public enum HealthPermission: String, Sendable, Equatable {
    case notDetermined, denied, authorized
}

public struct HealthPermissions: Sendable, Equatable {
    public enum Summary: Sendable, Equatable { case notDetermined, allowed, partial, denied }

    public let write: [HealthDataType: HealthPermission]

    public init(write: [HealthDataType: HealthPermission]) { self.write = write }

    public static let notDetermined = HealthPermissions(
        write: Dictionary(uniqueKeysWithValues: HealthDataType.allCases.map { ($0, .notDetermined) }))

    public func permission(_ type: HealthDataType) -> HealthPermission { write[type] ?? .notDetermined }

    public var summary: Summary {
        let values = HealthDataType.allCases.map(permission)
        if values.allSatisfy({ $0 == .authorized }) { return .allowed }
        if values.allSatisfy({ $0 == .notDetermined }) { return .notDetermined }
        if values.contains(.authorized) { return .partial }
        return values.contains(.notDetermined) ? .notDetermined : .denied
    }
}

/// A finished workout as written to Health. `externalId` is GymRollins' workout id (`HKMetadataKeyExternalUUID`).
public struct HealthWorkout: Sendable, Equatable {
    public let externalId: UUID
    public let name: String
    public let start: Date
    public let end: Date
    /// Estimated active energy (kcal, resting energy excluded); nil when there's no estimate (e.g. a very short
    /// workout).
    public let kcal: Double?
    public let activity: HealthActivityKind
    /// Time paused during the workout (written as a pause right before the end, so Health's duration matches).
    public let pausedSeconds: TimeInterval

    public init(externalId: UUID, name: String, start: Date, end: Date, kcal: Double?, activity: HealthActivityKind,
                pausedSeconds: TimeInterval = 0) {
        self.externalId = externalId
        self.name = name
        self.start = start
        self.end = end
        self.kcal = kcal
        self.activity = activity
        self.pausedSeconds = pausedSeconds
    }

    var withoutEnergy: HealthWorkout {
        HealthWorkout(externalId: externalId, name: name, start: start, end: end, kcal: nil, activity: activity,
                      pausedSeconds: pausedSeconds)
    }

    /// Changes whenever anything written to Health would change.
    var fingerprint: String {
        [externalId.uuidString, name, "\(start.timeIntervalSince1970)", "\(end.timeIntervalSince1970)",
         kcal.map { "\(Int($0.rounded()))" } ?? "-", activity.rawValue, "\(Int(pausedSeconds))"]
            .joined(separator: "|")
    }
}

/// A GymRollins workout found in Health (any copy carrying its external id): the phone exporter's estimate, or the
/// Apple Watch app's measured recording (synced to the phone's Health store). Told apart by
/// `WatchHealthRules.isWatchRecording` (writer metadata, else recording device), never by HealthKit source — a
/// companion watch app's samples may carry the iOS app's source.
public struct HealthWorkoutCopy: Sendable, Equatable {
    public let externalId: UUID
    /// Written by the phone's exporter (false: the watch's recording).
    public let writtenByThisApp: Bool

    public init(externalId: UUID, writtenByThisApp: Bool) {
        self.externalId = externalId
        self.writtenByThisApp = writtenByThisApp
    }
}

/// A weigh-in logged in the app, written to Health as a body mass sample (+ a body fat sample when set).
public struct HealthWeighIn: Sendable, Equatable {
    public let externalId: UUID
    public let date: Date
    public let weightKg: Double
    /// Percent, 0–100.
    public let bodyFatPct: Double?

    public init(externalId: UUID, date: Date, weightKg: Double, bodyFatPct: Double?) {
        self.externalId = externalId
        self.date = date
        self.weightKg = weightKg
        self.bodyFatPct = bodyFatPct
    }

    var fingerprint: String {
        [externalId.uuidString, "\(date.timeIntervalSince1970)", "\(weightKg)", bodyFatPct.map { "\($0)" } ?? "-"]
            .joined(separator: "|")
    }
}

public enum HealthBodyKind: String, Sendable, Codable {
    case bodyMass, bodyFat
}

/// A body sample read from Health. `value` is kg for body mass and percent (0–100) for body fat.
public struct HealthBodySample: Sendable, Equatable {
    public let uuid: UUID
    public let kind: HealthBodyKind
    public let value: Double
    public let date: Date
    /// Written by GymRollins itself (never imported back).
    public let fromThisApp: Bool
    public let sourceName: String

    public init(uuid: UUID = UUID(), kind: HealthBodyKind, value: Double, date: Date, fromThisApp: Bool = false,
                sourceName: String = "Health") {
        self.uuid = uuid
        self.kind = kind
        self.value = value
        self.date = date
        self.fromThisApp = fromThisApp
        self.sourceName = sourceName
    }
}

/// One anchored read: samples added and ids deleted since `anchor`, and the anchor to resume from.
public struct HealthBodyChanges: Sendable, Equatable {
    public let added: [HealthBodySample]
    public let deleted: [UUID]
    public let anchor: Data?

    public init(added: [HealthBodySample], deleted: [UUID], anchor: Data?) {
        self.added = added
        self.deleted = deleted
        self.anchor = anchor
    }
}

/// The seam around HealthKit: `HealthKitStore` on device, `FakeHealthStore` in tests and `-fakeHealth` UI tests.
public protocol HealthStore: Sendable {
    /// False on devices without Health (some iPads) and on the Mac: nothing else may be called then.
    var isAvailable: Bool { get }
    func requestAuthorization() async throws
    func permissions() async -> HealthPermissions
    /// Saves a workout; callers delete any previous copy (`deleteWorkout(externalId:)`) first.
    func save(workout: HealthWorkout) async throws
    /// Deletes this app's workout with this external id (no-op when there is none), and its energy sample when
    /// `withEnergy`. Throws when a type that has to be deleted isn't writable, so the caller retries later.
    func deleteWorkout(externalId: UUID, withEnergy: Bool) async throws
    /// Every workout in Health with this external id, from any source (plan 17: the watch's copy). Needs read access
    /// to workouts; without it only this app's own copies (or none) come back.
    func workoutCopies(externalId: UUID) async throws -> [HealthWorkoutCopy]
    /// Like `deleteWorkout`, but only the phone exporter's copy: the watch's measured recording always stays.
    func deleteOwnWorkout(externalId: UUID, withEnergy: Bool) async throws
    func save(weighIn: HealthWeighIn) async throws
    func deleteWeighIn(externalId: UUID, withBodyFat: Bool) async throws
    /// Body mass and body fat samples dated on/after `start`, added or deleted since `anchor` (all when nil).
    func bodyChanges(since start: Date, anchor: Data?) async throws -> HealthBodyChanges
}
