import Foundation
import GymCore
import SwiftData

/// One muscle group's weekly target as synced (`public.muscle_targets` row).
public struct MuscleTargetValue: Sendable, Equatable {
    public let group: MuscleGroup
    public let range: SetTargetRange

    public init(group: MuscleGroup, range: SetTargetRange) {
        self.group = group
        self.range = range
    }
}

// Weekly set targets.
extension SyncStore {
    public func dirtyMuscleTargets() throws -> [SyncRow<MuscleTargetValue>] {
        try context.fetch(FetchDescriptor<MuscleTargetRecord>(predicate: #Predicate { $0.dirty },
                                                              sortBy: [SortDescriptor(\.muscle)]))
            .compactMap { r in
                MuscleGroup(rawValue: r.muscle).map {
                    SyncRow(value: MuscleTargetValue(group: $0, range: SetTargetRange(min: r.minSets, max: r.maxSets)),
                            clientUpdatedAt: r.updatedAt, serverUpdatedAt: r.serverUpdatedAt)
                }
            }
    }

    /// Applies pulled rows (last write wins against dirty local rows); rows the app can't store are skipped.
    public func applyRemote(muscleTargets rows: [SyncRow<MuscleTargetValue>]) throws {
        for row in rows where row.value.range.isValid {
            let existing = try muscleTargetRecord(row.value.group.rawValue)
            if let existing, !remoteWins(over: existing, remoteEdit: row.clientUpdatedAt) { continue }
            let r = existing ?? {
                let new = MuscleTargetRecord(muscle: row.value.group.rawValue, minSets: row.value.range.min,
                                             maxSets: row.value.range.max, now: row.clientUpdatedAt)
                context.insert(new)
                return new
            }()
            r.minSets = row.value.range.min
            r.maxSets = row.value.range.max
            markClean(r, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: row.serverUpdatedAt)
        }
        try context.save()
    }

    func muscleTargetRecord(_ muscle: String) throws -> MuscleTargetRecord? {
        try context.fetch(FetchDescriptor<MuscleTargetRecord>(predicate: #Predicate { $0.muscle == muscle })).first
    }
}
