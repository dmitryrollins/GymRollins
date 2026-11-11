import Foundation
import GymCore

/// Where `TodayPlanEditor` keeps the day's changes: `TodayPlanStore` for today, `LaterDayPlanSaver` for a later day.
protocol TodayPlanSaving {
    func save(_ plan: TodayPlan)
    func clear()
}

extension TodayPlanStore: TodayPlanSaving {}

/// The owner's changes to later days (owner, 2026-11-10): yyyy-MM-dd → that day's `TodayPlan`, kept on this iPhone
/// (UserDefaults, like `PlannedSwitchStore`) and never synced. On the day, Today takes the entry and stores it as
/// today's plan (`AppEnvironment.takeLaterDayPlan`); an agent's later `today` change for the date replaces it.
struct LaterDayPlanStore {
    static let key = "gymrollins.laterDayPlans"
    let defaults: UserDefaults

    /// The change stored for `day`, under the rules today's stored plan follows (`TodayPlanStore.current`). Nil when
    /// there is none, its workout is gone, or the schedule moved on from it.
    func plan(day: String, routines: [Routine], scheduled: UUID?) -> TodayPlan? {
        guard let plan = all()[day] else { return nil }
        if let base = plan.base, !routines.contains(where: { $0.id == base.id }) { return nil }
        return TodayPlanStore.current(plan, routines: routines, scheduled: scheduled)
    }

    /// The dates that have a change stored.
    func days() -> Set<String> { Set(all().keys) }

    func save(_ plan: TodayPlan) {
        write(all().merging([plan.day: plan]) { _, new in new })
    }

    func remove(day: String) {
        write(all().filter { $0.key != day })
    }

    /// The change stored for `day`, removed from the store along with anything for earlier days.
    func take(day: String) -> TodayPlan? {
        let current = all()
        guard current.keys.contains(where: { $0 <= day }) else { return nil }
        write(current.filter { $0.key > day })
        return current[day]
    }

    func clear() { defaults.removeObject(forKey: Self.key) }

    private func all() -> [String: TodayPlan] {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode([String: TodayPlan].self, from: data) else { return [:] }
        return stored
    }

    private func write(_ entries: [String: TodayPlan]) {
        guard !entries.isEmpty, let data = try? JSONEncoder().encode(entries) else { clear(); return }
        defaults.set(data, forKey: Self.key)
    }
}
