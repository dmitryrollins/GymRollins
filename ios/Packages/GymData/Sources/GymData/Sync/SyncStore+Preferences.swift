import Foundation
import GymCore
import SwiftData

/// One exercise's recommendation preference as synced (`public.exercise_prefs`).
public struct ExercisePreferenceSetting: Sendable, Equatable {
    public let exerciseId: String
    public let preference: ExercisePreference

    public init(exerciseId: String, preference: ExercisePreference) {
        self.exerciseId = exerciseId
        self.preference = preference
    }
}

extension ExercisePreferenceRecord: SyncTracked {}

// Exercise preferences.
extension SyncStore {
    public func dirtyExercisePreferences() throws -> [SyncRow<ExercisePreferenceSetting>] {
        try context.fetch(FetchDescriptor<ExercisePreferenceRecord>(predicate: #Predicate { $0.dirty },
                                                                    sortBy: [SortDescriptor(\.id)]))
            .map { SyncRow(value: ExercisePreferenceSetting(exerciseId: $0.id,
                                                            preference: ExercisePreference(storedValue: $0.prefRaw)),
                           clientUpdatedAt: $0.updatedAt, serverUpdatedAt: $0.serverUpdatedAt) }
    }

    public func applyRemote(exercisePreferences rows: [SyncRow<ExercisePreferenceSetting>]) throws {
        for row in rows where ExercisePreferenceRepository.isValidExerciseId(row.value.exerciseId) {
            let existing = try exercisePreferenceRecord(row.value.exerciseId)
            if let existing, !remoteWins(over: existing, remoteEdit: row.clientUpdatedAt) { continue }
            let r = existing ?? {
                let new = ExercisePreferenceRecord(id: row.value.exerciseId, prefRaw: row.value.preference.rawValue,
                                                   now: row.clientUpdatedAt)
                context.insert(new)
                return new
            }()
            r.prefRaw = row.value.preference.rawValue
            markClean(r, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: row.serverUpdatedAt)
        }
        try context.save()
    }

    func exercisePreferenceRecord(_ id: String) throws -> ExercisePreferenceRecord? {
        try context.fetch(FetchDescriptor<ExercisePreferenceRecord>(predicate: #Predicate { $0.id == id })).first
    }
}
