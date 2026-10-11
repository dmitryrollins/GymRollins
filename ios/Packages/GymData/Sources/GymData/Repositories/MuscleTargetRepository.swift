import Foundation
import GymCore
import SwiftData

/// Weekly hard-set targets per muscle group: stored overrides on top of `MuscleGroup.defaultTarget`.
@MainActor
public final class MuscleTargetRepository {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    /// Every group's target: the stored one, else the default.
    public func all() throws -> [MuscleGroup: SetTargetRange] {
        var out = MuscleGroup.defaultTargets
        for r in try context.fetch(FetchDescriptor<MuscleTargetRecord>()) {
            guard let group = MuscleGroup(rawValue: r.muscle) else { continue }
            out[group] = SetTargetRange(min: r.minSets, max: r.maxSets)
        }
        return out
    }

    /// Groups whose stored target differs from the default.
    public func customized() throws -> Set<MuscleGroup> {
        Set(try all().filter { $0.value != $0.key.defaultTarget }.map(\.key))
    }

    public func set(_ group: MuscleGroup, _ range: SetTargetRange) throws {
        guard range.isValid else {
            let limit = DomainLimits.weeklySetTarget
            throw GymDataError.invalidInput(
                "Weekly targets are \(limit.lowerBound)\u{2013}\(limit.upperBound) sets, with the minimum at or below the maximum.")
        }
        try write(group, range)
        try context.save()
    }

    /// Back to the defaults. Stored rows are rewritten (not deleted) so the reset syncs to other devices.
    public func resetAll() throws {
        for r in try context.fetch(FetchDescriptor<MuscleTargetRecord>()) {
            guard let group = MuscleGroup(rawValue: r.muscle), SetTargetRange(min: r.minSets, max: r.maxSets)
                    != group.defaultTarget else { continue }
            try write(group, group.defaultTarget)
        }
        try context.save()
    }

    private func write(_ group: MuscleGroup, _ range: SetTargetRange) throws {
        let key = group.rawValue
        let existing = try context.fetch(FetchDescriptor<MuscleTargetRecord>(
            predicate: #Predicate { $0.muscle == key })).first
        let r = existing ?? {
            let new = MuscleTargetRecord(muscle: key, minSets: range.min, maxSets: range.max, now: now())
            context.insert(new)
            return new
        }()
        r.minSets = range.min
        r.maxSets = range.max
        r.updatedAt = now()
        r.dirty = true
    }
}
