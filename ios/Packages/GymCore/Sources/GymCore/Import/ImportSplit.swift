import Foundation

/// A workout from an export, cut into pieces the server stores (server/src/sync/workouts.ts): at most
/// `DomainLimits.workoutEntriesMax` exercises a piece, and at most `DomainLimits.entrySetsMax` sets an exercise.
/// - An exercise with more sets goes on as another entry of the same exercise, in the next piece when this one is full.
/// - Piece 1 keeps the source's id, title and note, and starts at its start. Piece k has an id of its own made from the
///   source's (the same on every import), and names the source in `splitFrom`. The app titles it "<title> (k)"
///   (`name(_:part:)`).
/// - The pieces follow each other through the session, so its time is counted once (`times(_:sets:)`).
public enum ImportSplit {
    public static func pieces(_ workout: ImportedWorkout) -> [ImportedWorkout] {
        let entries = workout.entries.flatMap(runs)
        if entries.count <= DomainLimits.workoutEntriesMax && entries.count == workout.entries.count { return [workout] }
        let groups = stride(from: 0, to: entries.count, by: DomainLimits.workoutEntriesMax).map {
            Array(entries[$0..<min($0 + DomainLimits.workoutEntriesMax, entries.count)])
        }
        let spans = times(workout, sets: groups.map { $0.reduce(0) { $0 + $1.sets.count } })
        return groups.enumerated().map { index, entries in
            ImportedWorkout(id: index == 0 ? workout.id : ImportID.make([workout.id.uuidString, "part", "\(index + 1)"]),
                            startedAt: spans[index].start, entries: entries, name: workout.name,
                            endedAt: spans[index].end, note: workout.note, part: index + 1,
                            splitFrom: index == 0 ? nil : workout.id)
        }
    }

    /// Each piece's start and end. With an end time at least a second a piece after the start, the session is shared
    /// out in order, by each piece's sets (equally when there are none), at least a second each: piece 1 starts at the
    /// source's start, each next one where the one before ended, and the last ends at the source's end. Otherwise
    /// piece k starts k - 1 seconds after the source, with the source's end, so the pieces still sort in order.
    private static func times(_ workout: ImportedWorkout, sets: [Int]) -> [(start: Date, end: Date?)] {
        let start = workout.startedAt
        let count = sets.count
        guard let end = workout.endedAt, end.timeIntervalSince(start) >= TimeInterval(count) else {
            return (0..<count).map { (start.addingTimeInterval(TimeInterval($0)), workout.endedAt) }
        }
        let span = end.timeIntervalSince(start)
        let weights = sets.contains { $0 > 0 } ? sets : sets.map { _ in 1 }
        let total = Double(weights.reduce(0, +))
        let shares = weights.reduce(into: [0]) { $0.append($0[$0.count - 1] + $1) }.map { span * Double($0) / total }
        // Offsets of the piece boundaries, each at least a second after the one before and before the end.
        var bounds = shares
        for i in 1..<count { bounds[i] = max(bounds[i], bounds[i - 1] + 1) }
        for i in stride(from: count - 1, to: 0, by: -1) { bounds[i] = min(bounds[i], bounds[i + 1] - 1) }
        return (0..<count).map { i in
            (start.addingTimeInterval(bounds[i]), i == count - 1 ? end : start.addingTimeInterval(bounds[i + 1]))
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
