import Foundation
import GymCore
import GymData

/// Everything exported for a full-data JSON backup. `version` lets a future importer detect an older shape.
struct ExportBackup: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let exportedAt: Date
    let profile: Profile
    let routines: [Routine]
    /// ISO weekday ("1"…"7") -> routine id. String keys (rather than `[Int: UUID]`) so every `JSONEncoder`
    /// encodes this as a JSON object instead of a flat key/value array.
    let schedule: [String: UUID]
    let workouts: [Workout]
    let bodyweight: [BodyweightEntry]
    let customExercises: [Exercise]
    let proposals: [Proposal]
    /// Muscle group id ("chest", "upper_back", …) -> weekly hard-set target (every group, defaults included).
    /// Optional so backups written before weekly targets existed still decode.
    let weeklyTargets: [String: SetTargetRange]?
    /// Exercise id -> "recommend more / less / never" (normal ones left out). Optional so older backups decode.
    let exercisePreferences: [String: ExercisePreference]?

    init(exportedAt: Date, profile: Profile, routines: [Routine], schedule: [String: UUID], workouts: [Workout],
         bodyweight: [BodyweightEntry], customExercises: [Exercise], proposals: [Proposal],
         weeklyTargets: [String: SetTargetRange]? = nil, exercisePreferences: [String: ExercisePreference]? = nil) {
        self.version = Self.currentVersion
        self.exportedAt = exportedAt
        self.profile = profile
        self.routines = routines
        self.schedule = schedule
        self.workouts = workouts
        self.bodyweight = bodyweight
        self.customExercises = customExercises
        self.proposals = proposals
        self.weeklyTargets = weeklyTargets
        self.exercisePreferences = exercisePreferences
    }
}

/// Builds a full-data JSON backup and a Fitbod-format CSV of workouts. The CSV's header matches
/// `FitbodImporter.expectedHeader` exactly, and its rows re-import through `FitbodImporter`/`ImportPlan` to the
/// same workouts (weights, reps, warm-up flags, cardio duration/distance, entry notes), so export/import round-trips.
@MainActor
struct ExportService {
    let profiles: ProfileRepository
    let routines: RoutineRepository
    let workouts: WorkoutRepository
    let body: BodyRepository
    let customExercises: CustomExerciseRepository
    let proposals: ProposalRepository
    /// Resolves an exercise id (library or custom) to its display name for the CSV's "Exercise" column.
    let exerciseName: (String) -> String
    var now: () -> Date = Date.init
    /// Weekly targets to include (nil leaves them out, e.g. in tests that don't need them).
    var muscleTargets: MuscleTargetRepository?
    /// Exercise preferences to include (nil leaves them out).
    var exercisePreferences: ExercisePreferenceRepository?

    private static let workoutFetchLimit = 100_000

    // MARK: JSON backup

    func backup() throws -> ExportBackup {
        let schedule = try routines.schedule()
        let combined = Dictionary(uniqueKeysWithValues: (try proposals.pending() + (try proposals.recent(limit: 1_000)))
            .map { ($0.id, $0) })
        let scheduleByWeekday = Dictionary(uniqueKeysWithValues: schedule.days.map { (String($0.key), $0.value) })
        return ExportBackup(exportedAt: now(), profile: try profiles.load(), routines: try routines.all(),
                            schedule: scheduleByWeekday, workouts: try workouts.recent(limit: Self.workoutFetchLimit),
                            bodyweight: try body.entries(since: nil), customExercises: try customExercises.all(),
                            proposals: Array(combined.values).sorted { $0.createdAt > $1.createdAt },
                            weeklyTargets: try muscleTargets.map { repo in
                                Dictionary(uniqueKeysWithValues: try repo.all().map { ($0.key.rawValue, $0.value) })
                            },
                            exercisePreferences: try exercisePreferences?.all())
    }

    func backupData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(backup())
    }

    /// Writes the JSON backup to a fresh file for sharing (any previous export file is removed first).
    func writeBackupFile() throws -> URL {
        let url = try Self.freshExportURL(name: "GymRollins-backup-\(Self.fileTimestamp(now()))", ext: "json")
        try backupData().write(to: url, options: .atomic)
        return url
    }

    // MARK: Export files

    /// Every export file lives here, so one call can remove them all (after sharing, on sign-out or erase) and a
    /// later export can never hand out a file built from older data or another account's data.
    static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("GymRollinsExports", isDirectory: true)
    }

    /// Deletes all export files. Missing files are fine; anything else is logged.
    static func removeExportFiles() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: exportDirectory.path) else { return }
        do { try fm.removeItem(at: exportDirectory) } catch {
            AppEnvironment.log.error("Remove export files failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func freshExportURL(name: String, ext: String) throws -> URL {
        removeExportFiles()
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        return exportDirectory.appendingPathComponent(name).appendingPathExtension(ext)
    }

    // MARK: Fitbod-format CSV

    func workoutsCSV() throws -> String {
        let all = try workouts.recent(limit: Self.workoutFetchLimit).sorted { $0.startedAt < $1.startedAt }
        var lines = [FitbodImporter.expectedHeader.joined(separator: ",")]
        for workout in all {
            let dateField = Self.csvDateFormatter.string(from: workout.startedAt)
            for entry in workout.entries {
                let name = exerciseName(entry.exerciseId)
                for set in entry.sets {
                    lines.append(Self.row(dateField: dateField, exerciseName: name, set: set, note: entry.note ?? ""))
                }
            }
        }
        return lines.map { $0 + "\r\n" }.joined()
    }

    /// Writes the Fitbod-format CSV to a fresh file for sharing (any previous export file is removed first).
    func writeWorkoutsCSVFile() throws -> URL {
        let url = try Self.freshExportURL(name: "GymRollins-workouts-\(Self.fileTimestamp(now()))", ext: "csv")
        guard let data = try workoutsCSV().data(using: .utf8) else { throw GymDataError.invalidInput("Encoding") }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The entry's note goes on each of its rows; the importer joins an entry's distinct set notes, so it
    /// round-trips to the same note.
    private static func row(dateField: String, exerciseName: String, set: WorkoutSet, note: String) -> String {
        let fields = [dateField, csvEscape(exerciseName), String(set.reps), String(set.weightKg),
                      String(set.sec ?? 0), String(set.distanceM ?? 0), "0", "0", set.warmup ? "true" : "false",
                      csvEscape(note), String(set.multiplier)]
        return fields.joined(separator: ",")
    }

    /// First characters that make a spreadsheet treat a cell as a formula (CSV/formula injection).
    private static let formulaTriggers: Set<Character> = ["=", "+", "-", "@", "\t", "\r", "\r\n"]

    /// A text field (exercise name, note) for the CSV: prefixed with `'` when it starts like a formula, then quoted
    /// if it holds a comma, quote or line break. Numeric fields are written directly, never through this.
    static func csvEscape(_ field: String) -> String {
        let safe = field.first.map(formulaTriggers.contains) == true ? "'" + field : field
        guard safe.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return safe }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Same format `FitbodImporter` parses ("yyyy-MM-dd HH:mm:ss Z").
    private static let csvDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
