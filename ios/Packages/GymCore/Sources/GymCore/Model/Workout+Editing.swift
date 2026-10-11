import Foundation

extension WorkoutSet {
    public func with(weightKg: Double, reps: Int) -> WorkoutSet {
        WorkoutSet(id: id, weightKg: weightKg, reps: reps, sec: sec, minutes: minutes, distanceM: distanceM, done: done,
                   warmup: warmup, rir: rir, rpe: rpe, multiplier: multiplier, completedAt: completedAt)
    }

    public func with(sec: Int?) -> WorkoutSet {
        WorkoutSet(id: id, weightKg: weightKg, reps: reps, sec: sec, minutes: minutes, distanceM: distanceM, done: done,
                   warmup: warmup, rir: rir, rpe: rpe, multiplier: multiplier, completedAt: completedAt)
    }

    public func with(minutes: Double?, distanceM: Double?) -> WorkoutSet {
        WorkoutSet(id: id, weightKg: weightKg, reps: reps, sec: sec, minutes: minutes, distanceM: distanceM, done: done,
                   warmup: warmup, rir: rir, rpe: rpe, multiplier: multiplier, completedAt: completedAt)
    }

    public func with(multiplier: Double) -> WorkoutSet {
        WorkoutSet(id: id, weightKg: weightKg, reps: reps, sec: sec, minutes: minutes, distanceM: distanceM, done: done,
                   warmup: warmup, rir: rir, rpe: rpe, multiplier: multiplier, completedAt: completedAt)
    }

    /// Reps in reserve as rated after the set (`SetEffort`); nil clears it.
    public func with(rir: Double?) -> WorkoutSet {
        WorkoutSet(id: id, weightKg: weightKg, reps: reps, sec: sec, minutes: minutes, distanceM: distanceM, done: done,
                   warmup: warmup, rir: rir, rpe: rpe, multiplier: multiplier, completedAt: completedAt)
    }

    /// Fresh copy (new id, not done) used for "Add set".
    func duplicatedUndone() -> WorkoutSet {
        WorkoutSet(weightKg: weightKg, reps: reps, sec: sec, minutes: minutes, distanceM: distanceM, done: false,
                   warmup: false, multiplier: multiplier)
    }
}

extension WorkoutEntry {
    public func with(sets: [WorkoutSet]) -> WorkoutEntry {
        WorkoutEntry(id: id, exerciseId: exerciseId, sets: sets, note: note, supersetGroup: supersetGroup)
    }

    func with(exerciseId: String) -> WorkoutEntry {
        WorkoutEntry(id: id, exerciseId: exerciseId, sets: sets, note: note, supersetGroup: supersetGroup)
    }

    func with(note: String?) -> WorkoutEntry {
        WorkoutEntry(id: id, exerciseId: exerciseId, sets: sets, note: note, supersetGroup: supersetGroup)
    }
}

extension Workout {
    public func with(entries: [WorkoutEntry]) -> Workout {
        Workout(id: id, startedAt: startedAt, endedAt: endedAt, pausedSeconds: pausedSeconds, routineId: routineId,
                name: name, entries: entries, source: source, note: note)
    }

    public func with(endedAt: Date?, pausedSeconds: TimeInterval) -> Workout {
        Workout(id: id, startedAt: startedAt, endedAt: endedAt, pausedSeconds: pausedSeconds, routineId: routineId,
                name: name, entries: entries, source: source, note: note)
    }

    private func mappingEntry(_ entryId: UUID, _ transform: (WorkoutEntry) -> WorkoutEntry) -> Workout {
        guard entries.contains(where: { $0.id == entryId }) else { return self }
        return with(entries: entries.map { $0.id == entryId ? transform($0) : $0 })
    }

    public func updatingSet(entryId: UUID, setId: UUID, _ transform: (WorkoutSet) -> WorkoutSet) -> Workout {
        mappingEntry(entryId) { entry in entry.with(sets: entry.sets.map { $0.id == setId ? transform($0) : $0 }) }
    }

    public func appendingSet(entryId: UUID) -> Workout {
        mappingEntry(entryId) { entry in
            let template = entry.sets.last(where: { !$0.warmup }) ?? entry.sets.last
            let new = template?.duplicatedUndone() ?? WorkoutSet(weightKg: 0, reps: 8)
            return entry.with(sets: entry.sets + [new])
        }
    }

    public func insertingWarmup(entryId: UUID, set: WorkoutSet) -> Workout {
        mappingEntry(entryId) { entry in
            let index = entry.sets.firstIndex(where: { !$0.warmup }) ?? entry.sets.count
            return entry.with(sets: Array(entry.sets[..<index]) + [set] + Array(entry.sets[index...]))
        }
    }

    public func removingSet(entryId: UUID, setId: UUID) -> Workout {
        mappingEntry(entryId) { $0.with(sets: $0.sets.filter { $0.id != setId }) }
    }

    public func removingEntry(entryId: UUID) -> Workout {
        with(entries: entries.filter { $0.id != entryId })
    }

    public func replacingExercise(entryId: UUID, exerciseId: String) -> Workout {
        mappingEntry(entryId) { $0.with(exerciseId: exerciseId) }
    }

    public func appendingEntries(_ new: [WorkoutEntry]) -> Workout {
        with(entries: entries + new)
    }

    public func settingNote(entryId: UUID, note: String?) -> Workout {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return mappingEntry(entryId) { $0.with(note: trimmed?.isEmpty == true ? nil : trimmed) }
    }

    public var undoneSetCount: Int { entries.reduce(0) { $0 + $1.sets.filter { !$0.done }.count } }

    public var entriesWithUndoneSets: [WorkoutEntry] { entries.filter { $0.sets.contains { !$0.done } } }

    public func markingAllDone(at date: Date) -> Workout {
        with(entries: entries.map { e in e.with(sets: e.sets.map { $0.done ? $0 : $0.completing(at: date) }) })
    }

    /// Ends the workout. With `discardingUndone`, undone sets and then-empty entries are removed.
    public func finished(at date: Date, discardingUndone: Bool) -> Workout {
        let kept = discardingUndone
            ? entries.map { $0.with(sets: $0.sets.filter(\.done)) }.filter { !$0.sets.isEmpty }
            : entries
        return with(entries: kept).with(endedAt: date, pausedSeconds: pausedSeconds)
    }
}
