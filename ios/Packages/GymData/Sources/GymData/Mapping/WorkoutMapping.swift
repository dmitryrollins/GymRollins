import Foundation
import GymCore
import SwiftData

extension WorkoutRecord {
    public var value: Workout {
        Workout(id: id, startedAt: startedAt, endedAt: endedAt, pausedSeconds: pausedSeconds, routineId: routineId,
                name: name, entries: entryValues, source: WorkoutSource(rawValue: sourceRaw) ?? .app, note: note)
    }

    /// The entries in position order: from the `entriesData` cache when present, else from the relationship.
    public var entryValues: [WorkoutEntry] {
        if let data = entriesData, let cached = try? JSONDecoder().decode([WorkoutEntry].self, from: data) {
            return cached
        }
        return entries.sorted { $0.position < $1.position }.map(\.value)
    }

    /// Replaces the entry/set rows with `newEntries` and refreshes the `entriesData` cache. Every writer of a
    /// workout's entries must go through here so the cache never goes stale.
    func setEntries(_ newEntries: [WorkoutEntry], in context: ModelContext) throws {
        entries.forEach(context.delete)
        entries = newEntries.enumerated().map { WorkoutEntryRecord($1, position: $0) }
        entriesData = try JSONEncoder().encode(newEntries)
    }

    public var clock: WorkoutClock {
        WorkoutClock(startedAt: startedAt, pausedAt: pausedAt, pausedSeconds: pausedSeconds)
    }
}

extension WorkoutEntryRecord {
    public var value: WorkoutEntry {
        WorkoutEntry(id: id, exerciseId: exerciseId, sets: sets.sorted { $0.position < $1.position }.map(\.value),
                     note: note, supersetGroup: supersetGroup)
    }

    public convenience init(_ value: WorkoutEntry, position: Int) {
        self.init(id: value.id, exerciseId: value.exerciseId, position: position, note: value.note,
                  supersetGroup: value.supersetGroup)
        self.sets = value.sets.enumerated().map { SetRecord($1, position: $0) }
    }
}

extension SetRecord {
    public var value: WorkoutSet {
        WorkoutSet(id: id, weightKg: weightKg, reps: reps, sec: sec, minutes: minutes, distanceM: distanceM, done: done,
                   warmup: warmup, rir: rir, rpe: rpe, multiplier: multiplier, completedAt: completedAt)
    }

    public convenience init(_ value: WorkoutSet, position: Int) {
        self.init(id: value.id, position: position, weightKg: value.weightKg, reps: value.reps, sec: value.sec,
                  minutes: value.minutes, distanceM: value.distanceM, done: value.done, warmup: value.warmup,
                  rir: value.rir, rpe: value.rpe, multiplier: value.multiplier, completedAt: value.completedAt)
    }
}
