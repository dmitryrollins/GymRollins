import Foundation

/// The app a workout-history CSV came from.
public enum ImportSource: String, Sendable, Codable, CaseIterable, Identifiable {
    case fitbod, strong, hevy, fitNotes

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fitbod: "Fitbod"
        case .strong: "Strong"
        case .hevy: "Hevy"
        case .fitNotes: "FitNotes"
        }
    }
}

public enum DistanceUnit: String, Sendable, Codable, CaseIterable {
    case meters, kilometers, miles, feet, yards, inches, centimeters

    public static let metersPerMile = 1_609.344

    /// Unit abbreviations as exports write them (`m`, `km`, `mi`, `ft`, `yd`, `in`, `cm`, case-insensitive).
    public init?(abbreviation: String) {
        switch abbreviation.trimmingCharacters(in: .whitespaces).lowercased() {
        case "m", "meter", "meters", "metre", "metres": self = .meters
        case "km", "kms", "kilometer", "kilometers", "kilometre", "kilometres": self = .kilometers
        case "mi", "mile", "miles": self = .miles
        case "ft", "feet", "foot": self = .feet
        case "yd", "yds", "yard", "yards": self = .yards
        case "in", "inch", "inches": self = .inches
        case "cm", "centimeter", "centimeters", "centimetre", "centimetres": self = .centimeters
        default: return nil
        }
    }

    public func toMeters(_ value: Double) -> Double {
        switch self {
        case .meters: value
        case .kilometers: value * 1_000
        case .miles: value * Self.metersPerMile
        case .feet: value * 0.3048
        case .yards: value * 0.9144
        case .inches: value * 0.0254
        case .centimeters: value / 100
        }
    }
}

/// Settings an export doesn't always carry itself.
public struct ImportOptions: Sendable, Equatable {
    /// Unit of weight columns whose header and rows don't name one (Strong's current export uses the app setting).
    public var weightUnit: WeightUnit
    /// Time zone for timestamps written without an offset (Strong, Hevy, FitNotes write local wall-clock times).
    public var timeZone: TimeZone

    public init(weightUnit: WeightUnit = .kg, timeZone: TimeZone = .current) {
        self.weightUnit = weightUnit
        self.timeZone = timeZone
    }
}

public struct ImportedSet: Sendable, Equatable {
    public let weightKg: Double
    public let reps: Int
    public let durationSec: Int?
    public let distanceM: Double?
    public let warmup: Bool
    public let multiplier: Double
    public let note: String?
    public let rpe: Double?

    public init(weightKg: Double, reps: Int, durationSec: Int? = nil, distanceM: Double? = nil, warmup: Bool = false,
                multiplier: Double = 1, note: String? = nil, rpe: Double? = nil) {
        self.weightKg = weightKg
        self.reps = reps
        self.durationSec = durationSec
        self.distanceM = distanceM
        self.warmup = warmup
        self.multiplier = multiplier
        self.note = note
        self.rpe = rpe
    }
}

public struct ImportedEntry: Sendable, Equatable {
    public let exerciseName: String
    public let sets: [ImportedSet]
    /// Rows of one superset share a group (Hevy `superset_id`).
    public let supersetGroup: String?

    public init(exerciseName: String, sets: [ImportedSet], supersetGroup: String? = nil) {
        self.exerciseName = exerciseName
        self.sets = sets
        self.supersetGroup = supersetGroup
    }
}

public struct ImportedWorkout: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let entries: [ImportedEntry]
    /// Workout title from the export (Strong "Workout Name", Hevy `title`), nil when the format has none.
    public let name: String?
    /// End time when the export has one (Hevy `end_time`, Strong `Duration`).
    public let endedAt: Date?
    /// Workout-level note (Strong "Workout Notes", Hevy `description`).
    public let note: String?

    public init(id: UUID, startedAt: Date, entries: [ImportedEntry], name: String? = nil, endedAt: Date? = nil,
                note: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.entries = entries
        self.name = name
        self.endedAt = endedAt
        self.note = note
    }
}

public struct ImportRowError: Error, Sendable, Equatable {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

public struct WorkoutImportResult: Sendable, Equatable {
    public let workouts: [ImportedWorkout]
    public let rowErrors: [ImportRowError]
    public let warmupSetCount: Int
    /// Data rows in the file (excluding the header).
    public let rowCount: Int
    public let source: ImportSource
    /// Rows deliberately not imported (e.g. Strong's rest-timer rows, empty exercises), not errors.
    public let ignoredRowCount: Int

    public init(workouts: [ImportedWorkout], rowErrors: [ImportRowError], warmupSetCount: Int, rowCount: Int,
                source: ImportSource = .fitbod, ignoredRowCount: Int = 0) {
        self.workouts = workouts
        self.rowErrors = rowErrors
        self.warmupSetCount = warmupSetCount
        self.rowCount = rowCount
        self.source = source
        self.ignoredRowCount = ignoredRowCount
    }
}

/// Kept for callers written against the Fitbod-only importer.
public typealias FitbodImportResult = WorkoutImportResult

public enum WorkoutImportError: Error, Equatable, Sendable {
    case emptyFile
    case unrecognizedHeader([String])
    /// The user picked `selected`, but the header is `detected`'s export.
    case sourceMismatch(selected: ImportSource, detected: ImportSource)
}

/// Kept for callers written against the Fitbod-only importer.
public typealias FitbodImportError = WorkoutImportError
