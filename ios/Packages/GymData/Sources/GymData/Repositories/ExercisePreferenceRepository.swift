import Foundation
import GymCore
import SwiftData

/// Per-exercise "recommend more / less / never" choices.
@MainActor
public final class ExercisePreferenceRepository {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    /// Every exercise with a choice other than `normal`.
    public func all() throws -> [String: ExercisePreference] {
        try context.fetch(FetchDescriptor<ExercisePreferenceRecord>()).reduce(into: [:]) { result, record in
            let pref = ExercisePreference(storedValue: record.prefRaw)
            if pref != .normal { result[record.id] = pref }
        }
    }

    public func preference(for exerciseId: String) throws -> ExercisePreference {
        ExercisePreference(storedValue: try record(exerciseId)?.prefRaw)
    }

    /// Exercise ids marked "Don't recommend again", sorted.
    public func hidden() throws -> [String] {
        try all().filter { $0.value == .never }.keys.sorted()
    }

    /// Stores the choice (a no-op when it is already stored).
    public func set(_ preference: ExercisePreference, for exerciseId: String) throws {
        guard Self.isValidExerciseId(exerciseId) else {
            throw GymDataError.invalidInput("Unknown exercise.")
        }
        if let existing = try record(exerciseId) {
            guard existing.prefRaw != preference.rawValue else { return }
            existing.prefRaw = preference.rawValue
            existing.updatedAt = now()
            existing.dirty = true
        } else {
            context.insert(ExercisePreferenceRecord(id: exerciseId, prefRaw: preference.rawValue, now: now()))
        }
        try context.save()
    }

    /// Library ids ("0025") and custom ids ("custom-<uuid>"); matches the `exercise_prefs.exercise_id` check.
    public nonisolated static func isValidExerciseId(_ id: String) -> Bool {
        (1...80).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private func record(_ id: String) throws -> ExercisePreferenceRecord? {
        try context.fetch(FetchDescriptor<ExercisePreferenceRecord>(predicate: #Predicate { $0.id == id })).first
    }
}
