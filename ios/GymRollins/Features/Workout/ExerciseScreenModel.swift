import Foundation
import GymCore
import GymData

/// What the exercise screen (`LoggingView`) shows and edits: one entry of the running workout, or one exercise of
/// today's plan before it starts ("plan mode", opened from Today). The screen's shared parts (hero, chips, hint, set
/// timeline, Add Set) only go through this adapter; the few mode-specific parts switch on it.
@MainActor
enum ExerciseScreenModel {
    case workout(WorkoutSession, entryId: UUID)
    case plan(TodayPlanEditor, itemId: UUID)

    var isPlan: Bool {
        if case .plan = self { return true }
        return false
    }

    /// Identifies what the screen shows (the entry or the plan item).
    var id: UUID {
        switch self {
        case .workout(_, let entryId): entryId
        case .plan(_, let itemId): itemId
        }
    }

    var exerciseId: String? {
        switch self {
        case .workout(let session, let entryId): session.entry(entryId)?.exerciseId
        case .plan(let editor, let itemId): editor.item(itemId)?.exerciseId
        }
    }

    /// The sets, or nil once the entry / item is gone (the screen then closes).
    var sets: [WorkoutSet]? {
        switch self {
        case .workout(let session, let entryId): session.entry(entryId)?.sets
        case .plan(let editor, let itemId): editor.item(itemId) == nil ? nil : editor.sets(for: itemId)
        }
    }

    /// Today's sets were changed from the suggestion (plan mode only).
    var isEdited: Bool {
        if case .plan(let editor, let itemId) = self { return editor.isEdited(itemId) }
        return false
    }

    /// Rest between working sets: the running workout's, or today's.
    var restSeconds: TimeInterval {
        switch self {
        case .workout(let session, _): session.restSeconds
        case .plan(let editor, _): TimeInterval(editor.restSec)
        }
    }

    func setRestSeconds(_ seconds: TimeInterval) {
        switch self {
        case .workout(let session, _): session.restSeconds = seconds
        case .plan(let editor, _): editor.setRest(Int(seconds))
        }
    }

    func updateSet(_ setId: UUID, _ transform: (WorkoutSet) -> WorkoutSet) {
        switch self {
        case .workout(let session, let entryId): session.update(entryId: entryId, setId: setId, transform)
        case .plan(let editor, let itemId): editor.updateSet(itemId, setId: setId, transform)
        }
    }

    /// A set edit that, when it changes the set's weight, carries the new weight to the later sets still at the old
    /// one (`SetWeightCarry`), so one change sets the weight for the rest of the exercise.
    func updateSetCarryingWeight(_ setId: UUID, _ transform: (WorkoutSet) -> WorkoutSet) {
        guard let before = sets, let old = before.first(where: { $0.id == setId }) else {
            updateSet(setId, transform)
            return
        }
        let new = transform(old)
        updateSet(setId, transform)
        guard new.weightKg != old.weightKg else { return }
        for id in SetWeightCarry.following(before, edited: setId, fromKg: old.weightKg) {
            updateSet(id) { $0.with(weightKg: new.weightKg, reps: $0.reps) }
        }
    }

    func addSet() {
        switch self {
        case .workout(let session, let entryId): session.addSet(entryId: entryId)
        case .plan(let editor, let itemId): editor.addSet(itemId)
        }
    }

    /// A logged set stays; the last remaining (working) set can't go.
    func canRemoveSet(_ set: WorkoutSet) -> Bool {
        switch self {
        case .workout(let session, let entryId):
            // Looked up again: the set may have been logged (e.g. from the watch) since the menu was built.
            session.entry(entryId).map { entry in
                entry.sets.count > 1 && entry.sets.contains { $0.id == set.id && !$0.done }
            } ?? false
        case .plan(let editor, let itemId):
            editor.canRemoveSet(itemId, setId: set.id)
        }
    }

    func removeSet(_ set: WorkoutSet) {
        guard canRemoveSet(set) else { return }
        switch self {
        case .workout(let session, let entryId): session.removeSet(entryId: entryId, setId: set.id)
        case .plan(let editor, let itemId): editor.removeSet(itemId, setId: set.id)
        }
    }

    /// The set that shows the "Reps left?" chips: the latest logged working set of a reps exercise (workout only).
    func effortPromptSetId(mode: ExerciseMode) -> UUID? {
        guard case .workout(let session, let entryId) = self, let entry = session.entry(entryId) else { return nil }
        return SetEffort.promptSetId(in: entry.sets, mode: mode)
    }

    func rateSet(_ set: WorkoutSet, tapping choice: Int) {
        if case .workout(let session, let entryId) = self { session.rateSet(entryId: entryId, setId: set.id, tapping: choice) }
    }

    /// Warm-up ⇄ working is a planning choice: plan mode only.
    var canToggleWarmup: Bool { isPlan }

    func toggleWarmup(_ set: WorkoutSet) {
        if case .plan(let editor, let itemId) = self { editor.toggleWarmup(itemId, setId: set.id) }
    }

    /// Exercises Swap must not offer besides the current one: the plan's others (a plan holds each exercise once).
    var swapExcluded: Set<String> {
        guard case .plan(let editor, let itemId) = self else { return [] }
        return Set(editor.plan?.exercises.filter { $0.id != itemId }.map(\.exerciseId) ?? [])
    }

    /// Swaps the exercise. The workout's entry takes the new exercise's multiplier and suggested weight (`history` is
    /// the candidate's); today's plan takes its routine defaults, keeping the item's place and id.
    func swap(to candidate: Exercise, profile: Profile, history: [SessionResult]) {
        switch self {
        case .workout(let session, let entryId):
            session.swap(entryId: entryId, to: candidate.id, multiplier: SessionPlanner.multiplier(for: candidate),
                         workingWeightKg: SessionPlanner.swapWeightKg(exercise: candidate, profile: profile,
                                                                      history: history))
        case .plan(let editor, let itemId):
            editor.replace(itemId, with: RoutineDefaults.item(for: candidate, profile: profile))
        }
    }
}
