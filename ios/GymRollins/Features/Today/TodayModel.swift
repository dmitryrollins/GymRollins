import Foundation
import GymCore
import GymData

/// The current gym as Today's rows need it: built once per reload, so a row never queries the store.
struct TodayGymContext {
    let matcher: InventoryMatcher
    /// Listing id → its photo file.
    let photo: (UUID) -> String?

    /// Exercise id → the listing a built workout fitted it to, when that isn't the gym's first choice.
    var preferred: [String: UUID] = [:]

    /// The loads of the listing that decides this exercise's weight; nil when it has none here.
    func loads(for exerciseId: String) -> ListingLoads? {
        preferred[exerciseId].flatMap { matcher.listing($0)?.loads } ?? matcher.loads(for: exerciseId)
    }

    /// The listing `loads(for:)` reads, so a workout can record the one Today showed.
    func loadListingId(for exerciseId: String) -> UUID? {
        preferred[exerciseId].flatMap { matcher.listing($0)?.id } ?? matcher.loadListingId(for: exerciseId)
    }

    func preferring(_ listings: [String: UUID]) -> TodayGymContext {
        TodayGymContext(matcher: matcher, photo: photo, preferred: listings)
    }
}

struct TodayModel: Equatable {
    struct Row: Equatable, Identifiable {
        let id: UUID
        let exerciseId: String
        let name: String
        let bodyPart: String
        let subtitle: String
        let badge: String?
        let suggestedKg: Double?
        /// The sets were edited on Today (they no longer follow the suggestion).
        var setsEdited = false
        /// The photo of the gym listing this exercise uses.
        var photoFile: String?
    }

    let routineId: UUID?
    let title: String
    let summary: String
    let rows: [Row]

    static func make(routine: Routine?, profile: Profile, library: ExerciseLibrary,
                     history: (String) -> [SessionResult],
                     loads: (String) -> ListingLoads? = { _ in nil }) -> TodayModel {
        guard let routine else {
            return TodayModel(routineId: nil, title: "Rest day", summary: "Recover and eat well", rows: [])
        }
        let rows = routine.exercises.map { item -> Row in
            let ex = library.exercise(item.exerciseId)
            let target = PlannedTarget.make(item: item, policy: item.policy ?? routine.policy, profile: profile,
                                            exercise: ex, history: history(item.exerciseId),
                                            loads: loads(item.exerciseId))
            return Row(id: item.id, exerciseId: item.exerciseId, name: DisplayName.of(ex?.name ?? item.exerciseId),
                       bodyPart: ex?.bodyPart ?? "", subtitle: target.subtitle, badge: target.badge,
                       suggestedKg: target.suggestedKg)
        }
        let count = rows.count == 1 ? "1 exercise" : "\(rows.count) exercises"
        return TodayModel(routineId: routine.id, title: routine.name, summary: count, rows: rows)
    }

    /// Today's model for a `TodayPlan`: the rows of its exercises, with a summary saying what kind of day it is.
    static func make(plan: TodayPlan, profile: Profile, library: ExerciseLibrary,
                     history: (String) -> [SessionResult], gym: TodayGymContext? = nil,
                     loads: (String) -> ListingLoads? = { _ in nil }) -> TodayModel {
        let routine = plan.base?.with(exercises: plan.exercises) ?? Routine(name: plan.title, exercises: plan.exercises)
        let rows = make(routine: routine, profile: profile, library: library, history: history,
                        loads: loads).rows.map { row in
            guard let sets = plan.sets(for: row.id) else { return row }
            return Row(id: row.id, exerciseId: row.exerciseId, name: row.name, bodyPart: row.bodyPart,
                       subtitle: subtitle(sets: sets, unit: profile.unit), badge: nil,
                       suggestedKg: row.suggestedKg, setsEdited: true)
        }.map { withListingPhoto($0, gym: gym) }
        let count = rows.count == 1 ? "1 exercise" : "\(rows.count) exercises"
        let summary: String
        switch plan.kind {
        case .empty where rows.isEmpty: summary = "Add exercises, or start and add them as you go"
        case .restDaySuggestion where !plan.edited: summary = "Rest day \u{00B7} optional \u{00B7} \(count)"
        case .built: summary = count
        default: summary = plan.edited ? "\(count) \u{00B7} edited for today" : count
        }
        return TodayModel(routineId: plan.base?.id, title: plan.title, summary: summary, rows: rows)
    }

    /// The row with the photo of the gym listing it uses. The gym never marks or swaps a row: the plan stays as
    /// planned (owner, 2026-11-18).
    private static func withListingPhoto(_ row: Row, gym: TodayGymContext?) -> Row {
        guard let gym, case let .available(match) = gym.matcher.availability(of: row.exerciseId) else { return row }
        var row = row
        row.photoFile = ([match.loadListingId].compactMap { $0 } + match.listingIds).lazy.compactMap(gym.photo).first
        return row
    }

    /// "3 × 10 · 140 lb" for edited sets: working sets, their top reps (or seconds) and top weight (its pound number in
    /// lb).
    static func subtitle(sets: [WorkoutSet], unit: WeightUnit) -> String {
        let working = sets.filter { !$0.warmup }
        let top = working.map(\.reps).max() ?? 0
        let low = working.map(\.reps).min() ?? 0
        let secs = working.compactMap(\.sec).max()
        let amount = secs.map { "\($0) s" } ?? (low < top ? "\(low)\u{2013}\(top)" : "\(top)")
        let weight = TodaySetEdits.heaviest(working)
        let load = weight.kg > 0 ? " \u{00B7} " + WeightFormatter.format(kg: weight.kg, lb: weight.lb, unit: unit) : ""
        return "\(working.count) \u{00D7} \(amount)\(load)"
    }
}
