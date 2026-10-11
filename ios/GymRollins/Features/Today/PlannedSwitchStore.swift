import Foundation

/// Claude's `today` changes for a later date (up to 7 days ahead): yyyy-MM-dd → routine id, kept on this iPhone
/// (UserDefaults, like `TodayPlanStore`) until that day. On the day, Today takes the entry and stores it as a
/// switched plan — from then on it is exactly a Switch made that morning (editable, cleared by Start, gone the
/// next day). A switch for today itself goes straight into `TodayPlanStore`.
struct PlannedSwitchStore {
    static let key = "gymrollins.plannedSwitches"
    let defaults: UserDefaults

    func all() -> [String: UUID] {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode([String: UUID].self, from: data) else { return [:] }
        return stored
    }

    func set(_ routineId: UUID, on day: String) {
        write(all().merging([day: routineId]) { _, new in new })
    }

    /// Removes the entry for `day` if it still picks `routineId`.
    func remove(day: String, routineId: UUID) {
        let current = all()
        guard current[day] == routineId else { return }
        write(current.filter { $0.key != day })
    }

    /// The routine picked for `day`, removed from the store along with anything for earlier days.
    func take(day: String) -> UUID? {
        let current = all()
        guard current.keys.contains(where: { $0 <= day }) else { return nil }
        write(current.filter { $0.key > day })
        return current[day]
    }

    func clear() { defaults.removeObject(forKey: Self.key) }

    private func write(_ entries: [String: UUID]) {
        guard !entries.isEmpty, let data = try? JSONEncoder().encode(entries) else { clear(); return }
        defaults.set(data, forKey: Self.key)
    }
}
