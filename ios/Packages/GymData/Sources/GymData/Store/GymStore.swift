import Foundation
import SwiftData

public enum GymStore {
    public static let models: [any PersistentModel.Type] = [
        ProfileRecord.self, RoutineRecord.self, RoutineExerciseRecord.self, WeekdayRecord.self,
        WorkoutRecord.self, WorkoutEntryRecord.self, SetRecord.self, BodyweightRecord.self, CustomExerciseRecord.self,
        ProposalRecord.self, MuscleTargetRecord.self, ExercisePreferenceRecord.self,
    ]

    public static func container(inMemory: Bool, url: URL? = nil) throws -> ModelContainer {
        let config = url.map { ModelConfiguration(url: $0) } ?? ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: Schema(models), configurations: config)
    }
}
