import Foundation

/// A workout from an export, cut into pieces the server stores (server/src/sync/workouts.ts): at most
/// `DomainLimits.workoutEntriesMax` exercises a piece, and at most `DomainLimits.entrySetsMax` sets an exercise.
/// - An exercise with more sets goes on as another entry of the same exercise, in the next piece when this one is full.
/// - Piece 1 keeps the source's id, start, end, title and note. Piece k starts k - 1 seconds after it, so the pieces
///   sort in order next to each other, has an id of its own made from the source's (the same on every import), and
///   names the source in `splitFrom`. The app titles it "<title> (k)" (`name(_:part:)`).
public enum ImportSplit {
    public static func pieces(_ workout: ImportedWorkout) -> [ImportedWorkout] {
        let entries = workout.entries.flatMap(runs)
        if entries.count <= DomainLimits.workoutEntriesMax && entries.count == workout.entries.count { return [workout] }
        let groups = stride(from: 0, to: entries.count, by: DomainLimits.workoutEntriesMax).map {
            Array(entries[$0..<min($0 + DomainLimits.workoutEntriesMax, entries.count)])
        }
        return groups.enumerated().map { index, entries in
            ImportedWorkout(id: index == 0 ? workout.id : ImportID.make([workout.id.uuidString, "part", "\(index + 1)"]),
                            startedAt: workout.startedAt.addingTimeInterval(TimeInterval(index)), entries: entries,
                            name: workout.name, endedAt: workout.endedAt, note: workout.note, part: index + 1,
                            splitFrom: index == 0 ? nil : workout.id)
        }
    }

    /// The title the user sees on piece `part`: the export's title (or the app's default), then " (2)", " (3)", …,
    /// within `DomainLimits.workoutNameMax`.
    public static func name(_ base: String, part: Int) -> String {
        guard part > 1 else { return String(base.prefix(DomainLimits.workoutNameMax)) }
        let suffix = " (\(part))"
        return String(base.prefix(DomainLimits.workoutNameMax - suffix.count)) + suffix
    }

    /// An entry's sets in runs of at most `DomainLimits.entrySetsMax`, each run an entry of its own.
    private static func runs(_ entry: ImportedEntry) -> [ImportedEntry] {
        guard entry.sets.count > DomainLimits.entrySetsMax else { return [entry] }
        return stride(from: 0, to: entry.sets.count, by: DomainLimits.entrySetsMax).map {
            ImportedEntry(exerciseName: entry.exerciseName,
                          sets: Array(entry.sets[$0..<min($0 + DomainLimits.entrySetsMax, entry.sets.count)]),
                          supersetGroup: entry.supersetGroup)
        }
    }
}
