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

    func preferring(_ listings: [String: UUID]) -> TodayGymContext {
        TodayGymContext(matcher: matcher, photo: photo, preferred: listings)
    }
}

/// What a row says about the current gym.
enum GymMark: Equatable {
    /// Today's session does `planned` instead, which this gym can't do for lack of `missingKind`.
    case swapped(planned: String, missingKind: String)
    /// This gym can't do it, and nothing similar either.
    case unavailable(missingKind: String)
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
        var gymMark: GymMark?
        /// The photo of the gym listing this exercise uses.
        var photoFile: String?
    }

    let routineId: UUID?
    let title: String
    let summary: String
    let rows: [Row]
    /// "1 exercise swapped for this gym. Your plan isn't changed." when the gym changed today's exercises.
    var gymNote: String?

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
        }.map { marked($0, plan: plan, library: library, gym: gym) }
        let count = rows.count == 1 ? "1 exercise" : "\(rows.count) exercises"
        let summary: String
        switch plan.kind {
        case .empty where rows.isEmpty: summary = "Add exercises, or start and add them as you go"
        case .restDaySuggestion where !plan.edited: summary = "Rest day \u{00B7} optional \u{00B7} \(count)"
        case .built: summary = count
        default: summary = plan.edited ? "\(count) \u{00B7} edited for today" : count
        }
        return TodayModel(routineId: plan.base?.id, title: plan.title, summary: summary, rows: rows,
                          gymNote: swappedNote(plan.gymSwaps.count))
    }

    private static func swappedNote(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        let what = count == 1 ? "1 exercise" : "\(count) exercises"
        return "\(what) swapped for this gym. Your plan isn't changed."
    }

    /// The row with what the gym says about it: swapped from the planned exercise, not doable here, and the photo of
    /// the listing it uses. A pinned row (chosen by hand) is never marked.
    private static func marked(_ row: Row, plan: TodayPlan, library: ExerciseLibrary, gym: TodayGymContext?) -> Row {
        guard let gym else { return row }
        var row = row
        let matcher = gym.matcher
        if case let .available(match) = matcher.availability(of: row.exerciseId) {
            row.photoFile = ([match.loadListingId].compactMap { $0 } + match.listingIds).lazy.compactMap(gym.photo).first
        }
        if let planned = plan.gymSwaps[row.id],
           case let .missing(kinds) = matcher.availability(of: planned.exerciseId) {
            let name = DisplayName.of(library.exercise(planned.exerciseId)?.name ?? planned.exerciseId)
            row.gymMark = .swapped(planned: name, missingKind: missingName(kinds, matcher))
        } else if !plan.gymPinned.contains(row.id), plan.gymSwaps[row.id] == nil,
                  case let .missing(kinds) = matcher.availability(of: row.exerciseId) {
            row.gymMark = .unavailable(missingKind: missingName(kinds, matcher))
        }
        return row
    }

    /// The first kind of the missing requirement group, lowercased ("preacher bench").
    private static func missingName(_ kinds: [String], _ matcher: InventoryMatcher) -> String {
        kinds.first.map { matcher.kind($0)?.name.lowercased() ?? $0 } ?? "equipment"
    }

    /// "3 × 10 · 140 lb" for edited sets: working sets, their top reps (or seconds) and top weight.
    static func subtitle(sets: [WorkoutSet], unit: WeightUnit) -> String {
        let working = sets.filter { !$0.warmup }
        let top = working.map(\.reps).max() ?? 0
        let low = working.map(\.reps).min() ?? 0
        let secs = working.compactMap(\.sec).max()
        let amount = secs.map { "\($0) s" } ?? (low < top ? "\(low)\u{2013}\(top)" : "\(top)")
        let weight = working.map(\.weightKg).max() ?? 0
        let load = weight > 0 ? " \u{00B7} " + WeightFormatter.format(kg: weight, unit: unit) : ""
        return "\(working.count) \u{00D7} \(amount)\(load)"
    }
}
