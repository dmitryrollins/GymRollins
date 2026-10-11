import Foundation

/// Digital Crown stepping for the watch's Log set: weight moves along the exercise's loadable grid (the phone's
/// plate/dumbbell increment, in the user's unit), reps by one.
public enum CrownStepper {
    public static let maxReps = 100
    /// Absorbs kg <-> lb float drift (134.9999999 lb is on the 135 lb grid point).
    private static let tolerance = 1e-6

    /// `weight` moved `steps` grid points. An off-grid weight (e.g. an imported 61.2 kg) first snaps to its neighbour
    /// in the crown's direction; zero steps keep it as is. Never below the grid's first point (or 0).
    public static func weight(_ weight: Double, steppedBy steps: Int, grid: WatchLoadGrid) -> Double {
        guard steps != 0, grid.step > 0 else { return weight }
        let position = (weight - grid.offset) / grid.step
        let nearest = position.rounded()
        let onGrid = abs(position - nearest) < tolerance
        let base = onGrid ? nearest : (steps > 0 ? position.rounded(.down) : position.rounded(.up))
        let index = max(0, base + Double(steps))
        return max(0, grid.offset + index * grid.step)
    }

    public static func reps(_ reps: Int, steppedBy steps: Int) -> Int {
        min(max(0, reps + steps), maxReps)
    }
}

/// Command ids the phone already applied (persisted, newest last, bounded), so a command delivered twice — a
/// `sendMessage` whose reply was lost plus its `transferUserInfo` fallback — changes the workout once.
public struct WatchCommandLedger: Codable, Sendable, Equatable {
    public static let defaultCapacity = 200
    public let ids: [UUID]
    public let capacity: Int

    public init(capacity: Int = WatchCommandLedger.defaultCapacity) {
        self.init(ids: [], capacity: capacity)
    }

    private init(ids: [UUID], capacity: Int) {
        self.ids = ids
        self.capacity = max(1, capacity)
    }

    public func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// A copy that also remembers `id` (dropping the oldest beyond `capacity`).
    public func recording(_ id: UUID) -> WatchCommandLedger {
        guard !contains(id) else { return self }
        return WatchCommandLedger(ids: Array((ids + [id]).suffix(capacity)), capacity: capacity)
    }
}
