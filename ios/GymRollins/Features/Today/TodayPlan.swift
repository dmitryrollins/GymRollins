import Foundation
import GymCore

/// Today's workout before it starts. It is the scheduled routine; on an unplanned day, the routine done least
/// recently (a rest day you may still train on); or whatever the owner switched to. Replace / delete / add edit
/// today's copy only, and so do sets edited on Today's exercise screen (`setOverrides`) and today's rest;
/// `routineWithEdits` lets the owner save them back into the routine.
struct TodayPlan: Codable, Equatable {
    enum Kind: String, Codable {
        /// The routine scheduled for today.
        case scheduled
        /// Nothing scheduled: the next routine in rotation, offered as optional.
        case restDaySuggestion
        /// The owner picked another routine for today.
        case switched
        /// No routine: exercises picked by hand (possibly none yet).
        case empty
    }

    /// yyyy-MM-dd the plan belongs to (a stored plan is only reused that day).
    let day: String
    let kind: Kind
    /// The routine it came from (nil for an empty workout).
    let base: Routine?
    let exercises: [RoutineExercise]
    /// True while today's workout has changes "Save Changes" can write into `base`: replaced / deleted / added
    /// exercises or set edits not saved yet. (Today's rest is today-only: routines have no rest of their own.)
    let edited: Bool
    /// Sets edited on Today, by routine item id: exactly what Start Workout uses for that exercise (warm-ups
    /// included). Items without an entry follow the progression suggestion.
    let setOverrides: [UUID: [WorkoutSet]]
    /// Today's rest between working sets in seconds (nil = the profile default).
    let restSec: Int?
    /// The items in `setOverrides` edited since the last "Save Changes". Saved ones still start today's workout but
    /// are never written again, so a later save can't undo newer My Plan edits to them.
    let unsavedSetEdits: Set<UUID>

    init(day: String, kind: Kind, base: Routine?, exercises: [RoutineExercise], edited: Bool,
         setOverrides: [UUID: [WorkoutSet]] = [:], restSec: Int? = nil, unsavedSetEdits: Set<UUID>? = nil) {
        self.day = day
        self.kind = kind
        self.base = base
        self.exercises = exercises
        self.edited = edited
        self.setOverrides = setOverrides
        self.restSec = restSec
        self.unsavedSetEdits = unsavedSetEdits ?? (edited ? Set(setOverrides.keys) : [])
    }

    enum CodingKeys: String, CodingKey {
        case day, kind, base, exercises, edited, setOverrides, restSec, unsavedSetEdits
    }

    /// Plans stored before set editing existed have no `setOverrides` / `restSec`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(day: try c.decode(String.self, forKey: .day), kind: try c.decode(Kind.self, forKey: .kind),
                  base: try c.decodeIfPresent(Routine.self, forKey: .base),
                  exercises: try c.decode([RoutineExercise].self, forKey: .exercises),
                  edited: try c.decode(Bool.self, forKey: .edited),
                  setOverrides: try c.decodeIfPresent([UUID: [WorkoutSet]].self, forKey: .setOverrides) ?? [:],
                  restSec: try c.decodeIfPresent(Int.self, forKey: .restSec),
                  unsavedSetEdits: try c.decodeIfPresent(Set<UUID>.self, forKey: .unsavedSetEdits))
    }

    var title: String { base?.name ?? "Empty workout" }

    /// Anything that must survive a relaunch today (a switched or edited plan, or sets kept after saving).
    var hasTodayChanges: Bool { kind != .scheduled || edited || !setOverrides.isEmpty || restSec != nil }

    /// What `startSession` gets: the base routine (same id, name, policy) with today's exercises, an ad-hoc
    /// "Workout" for hand-picked exercises, or nil for a completely empty workout. Edited sets come separately
    /// (`setOverrides`).
    var routineToStart: Routine? {
        if let base { return base.with(exercises: exercises) }
        return exercises.isEmpty ? nil : Routine(name: "Workout", exercises: exercises)
    }

    /// Whether "Save Changes to <routine>" has something to save.
    var canSaveToRoutine: Bool { edited && base != nil }

    /// The routine with today's edits, for "Save to routine"; nil when there is no routine or nothing changed.
    /// Edited sets become the item's working set count, top reps (or seconds) and working weight, stamped `now` so
    /// the planned weight wins over progression next time. Warm-ups aren't stored (they are generated) and neither
    /// is today's rest (routines have no rest of their own).
    func routineWithEdits(at now: Date) -> Routine? {
        guard canSaveToRoutine, let base else { return nil }
        return base.with(exercises: exercises.map { item in
            guard unsavedSetEdits.contains(item.id), let sets = setOverrides[item.id] else { return item }
            return TodaySetEdits.routineItem(item, from: sets, at: now)
        })
    }

    // MARK: Building

    static func make(scheduled: Routine?, routines: [Routine], lastDone: [UUID: Date], day: String) -> TodayPlan {
        if let scheduled {
            return TodayPlan(day: day, kind: .scheduled, base: scheduled, exercises: scheduled.exercises, edited: false)
        }
        guard let next = suggestion(routines: routines, lastDone: lastDone) else {
            return TodayPlan(day: day, kind: .empty, base: nil, exercises: [], edited: false)
        }
        return TodayPlan(day: day, kind: .restDaySuggestion, base: next, exercises: next.exercises, edited: false)
    }

    /// The usable routine (not paused, has exercises) done least recently; never-done routines first, in plan order.
    static func suggestion(routines: [Routine], lastDone: [UUID: Date]) -> Routine? {
        let usable = routines.enumerated().filter { !$0.element.paused && !$0.element.exercises.isEmpty }
        return usable.min { a, b in
            let da = lastDone[a.element.id] ?? .distantPast, db = lastDone[b.element.id] ?? .distantPast
            return da != db ? da < db : a.offset < b.offset
        }?.element
    }

    // MARK: Edits (today only)

    func switched(to routine: Routine?) -> TodayPlan {
        guard let routine else { return TodayPlan(day: day, kind: .empty, base: nil, exercises: [], edited: false) }
        return TodayPlan(day: day, kind: .switched, base: routine, exercises: routine.exercises, edited: false)
    }

    func replacing(_ itemId: UUID, with item: RoutineExercise) -> TodayPlan {
        changed(exercises.map { $0.id == itemId ? item : $0 }, overrides: setOverrides.filter { $0.key != itemId },
                unsaved: unsavedSetEdits.subtracting([itemId]))
    }

    func deleting(_ itemId: UUID) -> TodayPlan {
        changed(exercises.filter { $0.id != itemId }, overrides: setOverrides.filter { $0.key != itemId },
                unsaved: unsavedSetEdits.subtracting([itemId]))
    }

    /// Appends exercises not already in the workout.
    func adding(_ items: [RoutineExercise]) -> TodayPlan {
        let present = Set(exercises.map(\.exerciseId))
        return changed(exercises + items.filter { !present.contains($0.exerciseId) })
    }

    /// Today's sets for one exercise, or nil when it follows the suggestion.
    func sets(for itemId: UUID) -> [WorkoutSet]? { setOverrides[itemId] }

    func hasSetEdits(_ itemId: UUID) -> Bool { setOverrides[itemId] != nil }

    /// Replaces one exercise's sets for today.
    func editingSets(_ itemId: UUID, _ sets: [WorkoutSet]) -> TodayPlan {
        guard exercises.contains(where: { $0.id == itemId }), !sets.isEmpty else { return self }
        var overrides = setOverrides
        overrides[itemId] = sets
        return changed(exercises, overrides: overrides, unsaved: unsavedSetEdits.union([itemId]))
    }

    /// Back to the progression suggestion for one exercise.
    func resettingSets(_ itemId: UUID) -> TodayPlan {
        changed(exercises, overrides: setOverrides.filter { $0.key != itemId },
                unsaved: unsavedSetEdits.subtracting([itemId]))
    }

    /// Today's rest between sets (nil = the profile default).
    func withRest(_ seconds: Int?) -> TodayPlan {
        changed(exercises, overrides: setOverrides, rest: .some(seconds))
    }

    /// After "Save to routine": the routine now matches, so the plan is no longer edited. Today's sets and rest stay,
    /// so the workout still starts with exactly what was shown.
    func savedToRoutine(at now: Date) -> TodayPlan {
        guard let saved = routineWithEdits(at: now) else { return self }
        return TodayPlan(day: day, kind: kind, base: saved, exercises: saved.exercises, edited: false,
                         setOverrides: setOverrides, restSec: restSec, unsavedSetEdits: [])
    }

    /// Today's exercises are exactly the base routine's (only sets or rest were edited).
    var exercisesMatchBase: Bool { base?.exercises == exercises }

    /// The same day's plan on the routine's current version, keeping today's sets for exercises still in it.
    func rebased(on routine: Routine) -> TodayPlan {
        // Same item *and* same exercise: a swap keeps the item's id but the sets belong to the old exercise.
        let before = Dictionary(exercises.map { ($0.id, $0.exerciseId) }, uniquingKeysWith: { first, _ in first })
        let kept = setOverrides.filter { id, _ in
            routine.exercises.contains { $0.id == id && $0.exerciseId == before[id] }
        }
        let unsaved = unsavedSetEdits.intersection(kept.keys)
        return TodayPlan(day: day, kind: kind, base: routine, exercises: routine.exercises, edited: !unsaved.isEmpty,
                         setOverrides: kept, restSec: restSec, unsavedSetEdits: unsaved)
    }

    private func changed(_ new: [RoutineExercise], overrides: [UUID: [WorkoutSet]]? = nil,
                         unsaved: Set<UUID>? = nil, rest: Int?? = nil) -> TodayPlan {
        let overrides = overrides ?? setOverrides
        let unsaved = (unsaved ?? unsavedSetEdits).intersection(overrides.keys)
        let exercisesDiffer = base.map { $0.exercises != new } ?? !new.isEmpty
        return TodayPlan(day: day, kind: kind, base: base, exercises: new, edited: exercisesDiffer || !unsaved.isEmpty,
                         setOverrides: overrides, restSec: rest ?? restSec, unsavedSetEdits: unsaved)
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

extension Routine {
    func with(exercises: [RoutineExercise]) -> Routine {
        Routine(id: id, name: name, emoji: emoji, policy: policy, paused: paused, exercises: exercises)
    }
}

/// Keeps today's switched or edited plan across relaunches (same day only, while its routine still exists). An
/// untouched scheduled plan isn't stored, so edits made in the Plan tab show up on Today right away.
struct TodayPlanStore {
    static let key = "gymrollins.todayPlan"
    let defaults: UserDefaults
    /// Called after every save or clear (`AppEnvironment.todayPlanStore` bumps its revision so the watch follows).
    var onChange: (() -> Void)?

    init(defaults: UserDefaults, onChange: (() -> Void)? = nil) {
        self.defaults = defaults
        self.onChange = onChange
    }

    /// Like `load(day:routineIds:)`, but a plan whose exercises weren't changed for today (only sets or rest, e.g.
    /// after Save Changes) follows its routine's current version: My Plan edits made since then show up, and nothing
    /// stale can be saved back over them. A plan with unsaved exercise changes keeps its snapshot.
    ///
    /// `scheduled` is the routine assigned to today now: a stored scheduled plan for another routine, or a rest-day
    /// suggestion on what has since become a training day, is dropped (the schedule changed; a switch is kept).
    func load(day: String, routines: [Routine], scheduled: UUID?) -> TodayPlan? {
        guard let plan = load(day: day, routineIds: Set(routines.map(\.id))) else { return nil }
        switch plan.kind {
        case .scheduled where plan.base?.id != scheduled: return nil
        case .restDaySuggestion where scheduled != nil: return nil
        default: break
        }
        guard !plan.edited || plan.exercisesMatchBase,
              let current = plan.base.flatMap({ base in routines.first { $0.id == base.id } }) else { return plan }
        return plan.rebased(on: current)
    }

    func load(day: String, routineIds: Set<UUID>) -> TodayPlan? {
        guard let data = defaults.data(forKey: Self.key),
              let plan = try? JSONDecoder().decode(TodayPlan.self, from: data), plan.day == day else { return nil }
        if let base = plan.base, !routineIds.contains(base.id) { return nil }
        return plan
    }

    func save(_ plan: TodayPlan) {
        guard plan.hasTodayChanges else { clear(); return }
        guard let data = try? JSONEncoder().encode(plan) else { return }
        defaults.set(data, forKey: Self.key)
        onChange?()
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
        onChange?()
    }
}
