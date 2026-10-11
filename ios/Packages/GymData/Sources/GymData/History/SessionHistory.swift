import Foundation
import GymCore

public enum SessionHistory {
    /// Working sets at the session's top weight become one progression data point (with their rated RIR).
    public static func result(for entry: WorkoutEntry, date: Date) -> SessionResult? {
        let working = WorkoutMetrics.workingSets(entry)
        guard let top = working.map(\.weightKg).max() else { return nil }
        let atTop = working.filter { abs($0.weightKg - top) < 0.01 }
        return SessionResult(date: date, weightKg: top, reps: atTop.map(\.reps), secs: atTop.compactMap(\.sec),
                             rir: atTop.contains { $0.rir != nil } ? atTop.map(\.rir) : [])
    }
}
