import Foundation
import GymCore
import SwiftData

@MainActor
public final class CustomExerciseRepository {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    public func all() throws -> [Exercise] {
        try context.fetch(FetchDescriptor<CustomExerciseRecord>(predicate: #Predicate { $0.deletedAt == nil },
                                                                sortBy: [SortDescriptor(\.name)]))
            .map { Exercise(id: $0.id, name: $0.name, bodyPart: $0.bodyPart, equipment: $0.equipment, target: $0.target,
                            isCustom: true, mode: ExerciseMode(rawValue: $0.modeRaw), bilateral: $0.bilateral) }
    }

    @discardableResult
    public func create(name: String, bodyPart: String, equipment: String, target: String, mode: ExerciseMode,
                       bilateral: Bool) throws -> Exercise {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let violation = DomainLimits.customExerciseNameViolation(trimmed) {
            throw GymDataError.invalidInput(violation)
        }
        let id = "custom-\(UUID().uuidString.lowercased())"
        context.insert(CustomExerciseRecord(id: id, name: trimmed, bodyPart: bodyPart, equipment: equipment,
                                            target: target, modeRaw: mode.rawValue, bilateral: bilateral, now: now()))
        try context.save()
        return Exercise(id: id, name: trimmed, bodyPart: bodyPart, equipment: equipment, target: target, isCustom: true,
                        mode: mode, bilateral: bilateral)
    }
}
