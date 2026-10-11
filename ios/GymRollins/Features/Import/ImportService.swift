import Foundation
import GymCore
import GymData

enum ImportServiceError: Error, Equatable {
    /// These names still resolve to `.needsChoice` after applying the user's choices.
    case unresolved([String])
}

struct ImportSummary: Equatable, Sendable {
    /// Workouts written (new or overwritten by a re-import); excludes `duplicatesSkipped`.
    let workouts: Int
    let sets: Int
    let warmupSets: Int
    let rowErrors: [ImportRowError]
    /// Custom exercises created by this run (empty on a re-import: existing ones are reused by name).
    let createdExercises: [Exercise]
    /// Workouts not imported because a different workout already in the log starts within
    /// `ImportService.duplicateWindow` (e.g. the same session exported from two apps).
    var duplicatesSkipped = 0
}

/// Saves an `ImportPlan` into the store. Workout ids come from the importer (a hash of the start key plus the
/// exercise names or workout title), so importing the same export again overwrites the same workouts instead of
/// duplicating them. A workout whose id is new but whose start is within `duplicateWindow` of a workout already
/// in the log is skipped as a duplicate (same session from another app's export, or an app workout re-imported
/// from our own Fitbod-format CSV).
///
/// Exports without an end time (Fitbod, FitNotes, some Strong rows) get an approximate `endedAt` (the sum of set
/// durations when every set is timed, otherwise at least 45 minutes). Every workout is marked
/// `note = "Imported from <App>"` (plus the export's workout note, if any).
@MainActor
final class ImportService {
    static let assumedDuration: TimeInterval = 45 * 60
    static let duplicateWindow: TimeInterval = 60
    static let batchSize = 20

    static func workoutNote(for source: ImportSource) -> String { "Imported from \(source.displayName)" }
    static func workoutName(for source: ImportSource) -> String { "\(source.displayName) workout" }

    private let workouts: WorkoutRepository
    private let customExercises: CustomExerciseRepository
    /// Used to infer the dumbbell pair multiplier for exports that don't carry one (all but Fitbod).
    private let library: ExerciseLibrary?

    init(workouts: WorkoutRepository, customExercises: CustomExerciseRepository, library: ExerciseLibrary? = nil) {
        self.workouts = workouts
        self.customExercises = customExercises
        self.library = library
    }

    /// Imports every workout in `plan`. `choices` answers the plan's `.needsChoice` names (and may override any
    /// other name). Imported workouts never produce "new record" notifications, so they are saved with no records.
    func importAll(plan: ImportPlan, choices: [String: ImportPlan.Resolution] = [:],
                   progress: (Double) -> Void = { _ in }) async throws -> ImportSummary {
        let final = plan.names.map { ($0, choices[$0] ?? plan.resolved($0)) }
        let unresolved = final.filter { if case .needsChoice = $0.1 { true } else { false } }.map(\.0)
        guard unresolved.isEmpty else { throw ImportServiceError.unresolved(unresolved) }
        progress(0)

        let (imported, duplicates) = try Self.withoutDuplicates(plan.result.workouts, source: plan.result.source,
                                                                existing: try workouts.recent(limit: 1_000_000))
        // Only names that still have sets after dropping duplicates get an id (and, if custom, an exercise).
        let kept = Set(imported.flatMap(\.entries).map(\.exerciseName))
        let (ids, created) = try exerciseIds(for: final.filter { kept.contains($0.0) }, workouts: imported)
        let source = plan.result.source
        let pairMultiplier = multiplier(source: source)
        for start in stride(from: 0, to: imported.count, by: Self.batchSize) {
            for workout in imported[start..<min(start + Self.batchSize, imported.count)] {
                try workouts.save(Self.workout(from: workout, exerciseIds: ids, source: source,
                                               multiplier: pairMultiplier), records: [])
            }
            progress(Double(min(start + Self.batchSize, imported.count)) / Double(max(imported.count, 1)))
            await Task.yield()
        }
        progress(1)
        let importedSets = imported.flatMap(\.entries).flatMap(\.sets)
        return ImportSummary(workouts: imported.count, sets: importedSets.count,
                             warmupSets: importedSets.filter(\.warmup).count, rowErrors: plan.stats.rowErrors,
                             createdExercises: created, duplicatesSkipped: duplicates)
    }

    /// Drops imported workouts that duplicate a *different* existing workout (start within `duplicateWindow`).
    /// A workout with the same id is kept: saving it overwrites the earlier import of the same export.
    /// Date-only exports (FitNotes: every day starts at a made-up noon) are never matched by time, in either
    /// direction, since their start says nothing about when the session happened.
    static func withoutDuplicates(_ imported: [ImportedWorkout], source: ImportSource = .fitbod,
                                  existing: [Workout]) throws -> ([ImportedWorkout], Int) {
        guard !isDateOnly(source) else { return (imported, 0) }
        let existingIds = Set(existing.map(\.id))
        let dateOnlyNote = workoutNote(for: .fitNotes)
        let starts = existing.filter { !($0.source == .import && ($0.note ?? "").hasPrefix(dateOnlyNote)) }
            .map(\.startedAt.timeIntervalSinceReferenceDate).sorted()
        let kept = imported.filter { workout in
            existingIds.contains(workout.id) || !hasStart(near: workout.startedAt, in: starts)
        }
        return (kept, imported.count - kept.count)
    }

    static func isDateOnly(_ source: ImportSource) -> Bool { source == .fitNotes }

    /// Binary search in sorted start times for one within `duplicateWindow` of `date`.
    private static func hasStart(near date: Date, in sorted: [TimeInterval]) -> Bool {
        let target = date.timeIntervalSinceReferenceDate
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < target - duplicateWindow { low = mid + 1 } else { high = mid }
        }
        return low < sorted.count && sorted[low] <= target + duplicateWindow
    }

    /// Exercise id per Fitbod name, creating custom exercises that don't exist yet (matched by normalized name).
    private func exerciseIds(for resolutions: [(String, ImportPlan.Resolution)],
                             workouts: [ImportedWorkout]) throws -> ([String: String], [Exercise]) {
        let existing = Dictionary(try customExercises.all().map { (ExerciseMatcher.normalize($0.name), $0.id) },
                                  uniquingKeysWith: { first, _ in first })
        var ids: [String: String] = [:]
        var created: [Exercise] = []
        for (name, resolution) in resolutions {
            switch resolution {
            case .library(let id):
                ids[name] = id
            case .custom:
                let key = ExerciseMatcher.normalize(name)
                if let id = existing[key] ?? created.first(where: { ExerciseMatcher.normalize($0.name) == key })?.id {
                    ids[name] = id
                } else {
                    let exercise = try createCustom(name: name, sets: Self.sets(named: name, in: workouts))
                    created.append(exercise)
                    ids[name] = exercise.id
                }
            case .needsChoice:
                break // rejected above
            }
        }
        return (ids, created)
    }

    private func createCustom(name: String, sets: [ImportedSet]) throws -> Exercise {
        let mode = ImportedExerciseTraits.mode(for: sets)
        let bodyPart = mode == .cardio ? "cardio" : ImportedExerciseTraits.bodyPart(for: name)
        return try customExercises.create(name: String(name.prefix(DomainLimits.customExerciseNameMax)),
                                          bodyPart: bodyPart, equipment: ImportedExerciseTraits.equipment(for: name),
                                          target: bodyPart, mode: mode, bilateral: false)
    }

    private static func sets(named name: String, in workouts: [ImportedWorkout]) -> [ImportedSet] {
        workouts.flatMap(\.entries).filter { $0.exerciseName == name }.flatMap(\.sets)
    }

    /// Per-exercise multiplier for sources without a multiplier column: Strong, Hevy and FitNotes log a dumbbell's
    /// weight per hand, so library dumbbell exercises count twice, as when logging in the app. Nil = keep the
    /// file's own value (Fitbod) or no library to decide from.
    private func multiplier(source: ImportSource) -> ((String) -> Double)? {
        guard source != .fitbod, let library else { return nil }
        return { id in Self.pairMultiplier(for: library.exercise(id)) }
    }

    /// Library words for dumbbell movements done with ONE dumbbell (goblet squat, one-arm work).
    private static let singleDumbbellWords = ["goblet", "one arm", "single arm", "concentration", "pullover",
                                              "side bend"]
    /// Single-dumbbell movements whose names don't say so (one dumbbell held in both hands).
    private static let singleDumbbellIds: Set<String> = ["2188"] // dumbbell seated triceps extension

    /// Same rule as logging in the app (`SessionPlanner.multiplier(for:)`: a custom exercise's "uses both
    /// dumbbells" setting, else 2 for library dumbbell movements), except that library movements done with one
    /// dumbbell (by name, or `singleDumbbellIds`) stay 1. Anything not listed follows the app's rule.
    static func pairMultiplier(for exercise: Exercise?) -> Double {
        let appRule = SessionPlanner.multiplier(for: exercise)
        guard let exercise, appRule == 2, !exercise.isCustom else { return appRule }
        let name = ExerciseMatcher.normalize(exercise.name)
        let single = singleDumbbellIds.contains(exercise.id) || singleDumbbellWords.contains { name.contains($0) }
        return single ? 1 : 2
    }

    static func workout(from imported: ImportedWorkout, exerciseIds: [String: String],
                        source: ImportSource = .fitbod, multiplier: ((String) -> Double)? = nil) -> Workout {
        let entries = imported.entries.compactMap { entry -> WorkoutEntry? in
            guard let id = exerciseIds[entry.exerciseName] else { return nil }
            let pair = multiplier?(id)
            let sets = entry.sets.map { set in
                WorkoutSet(weightKg: set.weightKg, reps: set.reps, sec: set.durationSec, distanceM: set.distanceM,
                           done: true, warmup: set.warmup, rpe: set.rpe, multiplier: pair ?? set.multiplier,
                           completedAt: imported.startedAt)
            }
            let notes = entry.sets.compactMap(\.note).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            return WorkoutEntry(exerciseId: id, sets: sets, note: notes.isEmpty ? nil : notes.joined(separator: "\n"),
                                supersetGroup: entry.supersetGroup)
        }
        let name = imported.name.map { String($0.prefix(DomainLimits.workoutNameMax)) } ?? workoutName(for: source)
        let note = [workoutNote(for: source), imported.note].compactMap { $0 }.joined(separator: "\n")
        return Workout(id: imported.id, startedAt: imported.startedAt, endedAt: endedAt(of: imported), name: name,
                       entries: entries, source: .import, note: note)
    }

    /// The export's end time when it is after the start, else the approximation from `duration(of:)`.
    static func endedAt(of workout: ImportedWorkout) -> Date {
        if let ended = workout.endedAt, ended > workout.startedAt { return ended }
        return workout.startedAt.addingTimeInterval(duration(of: workout))
    }

    /// Sum of set durations when every set is timed; otherwise at least `assumedDuration`.
    static func duration(of workout: ImportedWorkout) -> TimeInterval {
        let sets = workout.entries.flatMap(\.sets)
        let timed = TimeInterval(sets.compactMap(\.durationSec).reduce(0, +))
        let allTimed = !sets.isEmpty && sets.allSatisfy { $0.durationSec != nil }
        return allTimed ? timed : max(timed, assumedDuration)
    }
}
