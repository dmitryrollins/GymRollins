import Foundation
import SwiftData

/// A weekly hard-set target the owner set for one muscle group (`muscle` = `MuscleGroup.rawValue`). Groups
/// without a record use `MuscleGroup.defaultTarget`. Synced to `public.muscle_targets` (no tombstones).
@Model
public final class MuscleTargetRecord {
    @Attribute(.unique) public var muscle: String
    public var minSets: Int
    public var maxSets: Int
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool

    public init(muscle: String, minSets: Int, maxSets: Int, now: Date) {
        self.muscle = muscle
        self.minSets = minSets
        self.maxSets = maxSets
        self.updatedAt = now
        self.dirty = true
    }
}
