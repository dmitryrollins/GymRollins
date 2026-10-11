import Foundation
import GymCore
import Observation

/// Today's plan before the workout starts: the one copy Today and the plan-mode exercise screen both read and edit.
/// Every change is a today-only `TodayPlan` edit, saved for the rest of the day (`TodayPlanStore`).
///
/// Exercises without edited sets show what Start Workout would plan (`suggest`). That suggestion is computed once per
/// load and kept; a recomputed suggestion (after a reload or a history change) reuses the previous set ids row by row,
/// so typing in progress on the exercise screen still lands on the same rows.
@MainActor
@Observable
final class TodayPlanEditor {
    private(set) var plan: TodayPlan?
    /// A workout is running (Today started it, or the watch did): today's plan is spent and every edit is ignored, so
    /// a screen still open on it can't write it back.
    @ObservationIgnored var isLocked = false
    @ObservationIgnored private var store: TodayPlanStore?
    @ObservationIgnored private var defaultRestSec: Int
    @ObservationIgnored private var suggest: (RoutineExercise, TodayPlan) -> [WorkoutSet]
    /// Read from view bodies: ignored by observation so filling it never invalidates a view mid-update.
    @ObservationIgnored private var suggestions: [UUID: [WorkoutSet]] = [:]
    /// Set ids of dropped suggestions, by item (reused by the next suggestion for the same exercise).
    @ObservationIgnored private var previousIds: [UUID: (exerciseId: String, ids: [UUID], warmups: [Bool])] = [:]

    init(store: TodayPlanStore? = nil, defaultRestSec: Int = 90,
         suggest: @escaping (RoutineExercise, TodayPlan) -> [WorkoutSet] = { _, _ in [] }) {
        self.store = store
        self.defaultRestSec = defaultRestSec
        self.suggest = suggest
    }

    /// Points the editor at the app's store and planner (Today does this on every reload).
    func configure(store: TodayPlanStore, defaultRestSec: Int,
                   suggest: @escaping (RoutineExercise, TodayPlan) -> [WorkoutSet]) {
        self.store = store
        self.defaultRestSec = defaultRestSec
        self.suggest = suggest
    }

    /// Shows `plan` without saving it (a reload, or switching back to the scheduled routine).
    func load(_ plan: TodayPlan?) {
        invalidateSuggestions()
        if plan?.day != self.plan?.day { previousIds = [:] } // yesterday's typing must not land on today's plan
        self.plan = plan
    }

    /// Applies a today-only change and remembers it for the rest of the day (ignored while locked).
    func apply(_ new: TodayPlan) {
        guard !isLocked else { return }
        plan = new
        store?.save(new)
    }

    /// Forget cached suggestions (history changed, e.g. a workout was finished); their ids are kept for reuse.
    func invalidateSuggestions() {
        for (itemId, sets) in suggestions {
            if let exerciseId = item(itemId)?.exerciseId { previousIds[itemId] = (exerciseId, sets.map(\.id), sets.map(\.warmup)) }
        }
        suggestions = [:]
    }

    // MARK: One exercise

    func item(_ itemId: UUID) -> RoutineExercise? { plan?.exercises.first { $0.id == itemId } }

    func isEdited(_ itemId: UUID) -> Bool { plan?.hasSetEdits(itemId) ?? false }

    /// Today's sets for the item: the edited ones, or the (cached) suggestion.
    func sets(for itemId: UUID) -> [WorkoutSet] {
        guard let plan, let item = item(itemId) else { return [] }
        if let edited = plan.sets(for: itemId) { return edited }
        if let cached = suggestions[itemId] { return cached }
        let fresh = reusingIds(suggest(item, plan), itemId: itemId, exerciseId: item.exerciseId)
        suggestions[itemId] = fresh
        return fresh
    }

    func updateSet(_ itemId: UUID, setId: UUID, _ transform: (WorkoutSet) -> WorkoutSet) {
        let sets = sets(for: itemId)
        guard let index = sets.firstIndex(where: { $0.id == setId }) else { return }
        editSets(itemId, TodaySetEdits.replacing(sets, index: index, with: transform(sets[index])))
    }

    func addSet(_ itemId: UUID) { editSets(itemId, TodaySetEdits.adding(to: sets(for: itemId))) }

    func canRemoveSet(_ itemId: UUID, setId: UUID) -> Bool {
        let sets = sets(for: itemId)
        guard let set = sets.first(where: { $0.id == setId }) else { return false }
        return set.warmup || TodaySetEdits.workingCount(sets) > 1
    }

    func removeSet(_ itemId: UUID, setId: UUID) {
        let sets = sets(for: itemId)
        guard let index = sets.firstIndex(where: { $0.id == setId }) else { return }
        editSets(itemId, TodaySetEdits.removing(from: sets, index: index))
    }

    func toggleWarmup(_ itemId: UUID, setId: UUID) {
        let sets = sets(for: itemId)
        guard let index = sets.firstIndex(where: { $0.id == setId }) else { return }
        editSets(itemId, TodaySetEdits.togglingWarmup(sets, index: index))
    }

    func resetSets(_ itemId: UUID) {
        guard let plan, !isLocked else { return }
        forget(itemId) // the routine may have changed since (Save Changes)
        apply(plan.resettingSets(itemId))
    }

    /// Swaps the exercise for today, keeping the item's id (so an open exercise screen stays on it); its set edits go.
    func replace(_ itemId: UUID, with item: RoutineExercise) {
        // One exercise appears once in a plan (Save Changes and Claude's plan edits address exercises by id).
        guard let plan, !isLocked,
              !plan.exercises.contains(where: { $0.id != itemId && $0.exerciseId == item.exerciseId }) else { return }
        forget(itemId)
        apply(plan.replacing(itemId, with: item.withId(itemId)))
    }

    func delete(_ itemId: UUID) {
        guard let plan, !isLocked else { return }
        forget(itemId)
        apply(plan.deleting(itemId))
    }

    // MARK: Rest (today-wide)

    var restSec: Int { plan?.restSec ?? defaultRestSec }

    /// Today's rest; the profile default is stored as "none" so a later default change still applies.
    func setRest(_ seconds: Int) {
        guard let plan else { return }
        apply(plan.withRest(seconds == defaultRestSec ? nil : seconds))
    }

    private func forget(_ itemId: UUID) {
        suggestions[itemId] = nil
        previousIds[itemId] = nil
    }

    /// The previous suggestion's ids on the new one, row by row: same exercise and same rows (warm-up / working at the
    /// same positions) only, so a pending draft can never land on a different set.
    private func reusingIds(_ sets: [WorkoutSet], itemId: UUID, exerciseId: String) -> [WorkoutSet] {
        guard let previous = previousIds.removeValue(forKey: itemId), previous.exerciseId == exerciseId,
              previous.warmups == sets.map(\.warmup) else { return sets }
        return zip(sets, previous.ids).map { set, id in
            WorkoutSet(id: id, weightKg: set.weightKg, reps: set.reps, sec: set.sec, minutes: set.minutes,
                       distanceM: set.distanceM, warmup: set.warmup, multiplier: set.multiplier)
        }
    }

    private func editSets(_ itemId: UUID, _ new: [WorkoutSet]) {
        guard let plan, new != sets(for: itemId) else { return }
        apply(plan.editingSets(itemId, new))
    }
}

extension RoutineExercise {
    /// The same item under another id (Replace keeps the id of the item it replaces).
    func withId(_ newId: UUID) -> RoutineExercise {
        RoutineExercise(id: newId, exerciseId: exerciseId, sets: sets, reps: reps, repsMin: repsMin, sec: sec,
                        weightKg: weightKg, mode: mode, policy: policy, incKg: incKg, supersetGroup: supersetGroup,
                        weightSetAt: weightSetAt)
    }
}

extension TodayPlan {
    /// The started workout's entry for one of today's items: `SessionPlanner.start` keeps the items' order, and the
    /// entry must be the same exercise (never open another one).
    func entryId(for itemId: UUID, in workout: Workout) -> UUID? {
        guard let index = exercises.firstIndex(where: { $0.id == itemId }), workout.entries.indices.contains(index),
              workout.entries[index].exerciseId == exercises[index].exerciseId else { return nil }
        return workout.entries[index].id
    }
}
