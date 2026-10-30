import Foundation
import GymCore
import GymData
import Observation

extension BuildMuscle {
    /// "Back", "Arms": the chip's name.
    var title: String { rawValue.capitalized }
}

/// What the Build result screen says (spec §5 "Build workout"): the title, the banners and each row's words. Pure: the
/// screen gives it the built workout and what it needs to read the gym.
struct BuildResultModel: Equatable {
    enum Mark: Equatable {
        case repeated, noEquipment

        var text: String { self == .repeated ? "REPEAT" : "no equipment" }
    }

    struct Row: Equatable, Identifiable {
        let id: UUID
        let exerciseId: String
        let name: String
        /// "3 × 10 · 53 lb (24 kg)": what Start will start with.
        let subtitle: String
        /// The kind of the listing that decides the load ("Kettlebells"); nil for a no-equipment exercise.
        let listingName: String?
        /// The photo of that listing.
        let photoFile: String?
        let mark: Mark?
        /// "also Tuesday · no other Back option here" on a repeat.
        let reason: String?

        /// The line under the subtitle: the item it uses, then why it repeats.
        var note: String? {
            let parts = [listingName, reason].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
        }
    }

    let title: String
    let subtitle: String
    let rows: [Row]
    let thinNotices: [String]
    let skippedNotice: String?
    let shortNotice: String?

    var isEmpty: Bool { rows.isEmpty }
    /// Whether the screen offers "+ Add equipment": a chip ran out of fresh exercises, or nothing fits.
    var offersAddEquipment: Bool { !thinNotices.isEmpty || isEmpty }
    /// The exercises, as Start applies them.
    var exerciseIds: [String] { rows.map(\.exerciseId) }

    static func make(built: BuiltWorkout, muscles: [BuildMuscle], length: BuildLength, gymName: String,
                     gym: TodayGymContext?, profile: Profile, library: ExerciseLibrary,
                     history: (String) -> [SessionResult], calendar: Calendar = .current) -> BuildResultModel {
        let rows = built.items.map { row($0, gym: gym, profile: profile, library: library, history: history, calendar: calendar) }
        let count = rows.count == 1 ? "1 exercise" : "\(rows.count) exercises"
        return BuildResultModel(
            title: muscles.map(\.title).joined(separator: " + "),
            subtitle: "\(gymName) \u{00B7} \(count) \u{00B7} ~\(length.rawValue) min",
            rows: rows,
            thinNotices: built.thin.map { thinNotice($0, gymName: gymName) },
            skippedNotice: built.skipped.isEmpty ? nil
                : "No room for \(built.skipped.map(\.title).joined(separator: ", ")) at \(length.rawValue) min",
            shortNotice: !rows.isEmpty && rows.count < built.requestedSlots
                ? "\(rows.count) of \(built.requestedSlots) exercises. That's all this gym has for these muscles right now."
                : nil)
    }

    private static func row(_ item: BuiltItem, gym: TodayGymContext?, profile: Profile, library: ExerciseLibrary,
                            history: (String) -> [SessionResult], calendar: Calendar) -> Row {
        let planned = item.exercise
        let exercise = library.exercise(planned.exerciseId)
        let target = PlannedTarget.make(item: planned, policy: planned.policy ?? .double, profile: profile,
                                        exercise: exercise, history: history(planned.exerciseId),
                                        loads: item.match.loadListingId.flatMap { gym?.matcher.listing($0)?.loads })
        let listingIds = ([item.match.loadListingId].compactMap { $0 } + item.match.listingIds)
        let listingName = listingIds.lazy.compactMap { id in
            gym?.matcher.listing(id).flatMap { gym?.matcher.kind($0.kindId)?.name }
        }.first
        let mark: Mark? = item.isBodyweightFill ? .noEquipment : (item.repeatOf != nil ? .repeated : nil)
        return Row(id: planned.id, exerciseId: planned.exerciseId,
                   name: DisplayName.of(exercise?.name ?? planned.exerciseId), subtitle: target.subtitle,
                   listingName: item.isBodyweightFill ? nil : listingName,
                   photoFile: item.isBodyweightFill ? nil : listingIds.lazy.compactMap { gym?.photo($0) }.first,
                   mark: mark, reason: item.repeatOf.map { repeatReason($0, muscle: item.muscle, calendar: calendar) })
    }

    private static func repeatReason(_ date: Date, muscle: BuildMuscle, calendar: Calendar) -> String {
        let weekday = calendar.weekdaySymbols[calendar.component(.weekday, from: date) - 1]
        return "also \(weekday) \u{00B7} no other \(muscle.title) option here"
    }

    private static func thinNotice(_ notice: ThinInventoryNotice, gymName: String) -> String {
        let more = "Add a photo to unlock more variety."
        switch notice.itemCount {
        case 0: return "No \(notice.muscle.title) equipment catalogued at \(gymName) yet. \(more)"
        case 1: return "Only 1 \(notice.muscle.title) item catalogued at \(gymName) so far. \(more)"
        default: return "Only \(notice.itemCount) \(notice.muscle.title) items catalogued at \(gymName) so far. \(more)"
        }
    }
}

/// What Start hands to Today: the title, the exercises, and the listing each exercise's weight was fitted to.
struct BuiltStart: Equatable {
    let name: String
    let items: [RoutineExercise]
    let listings: [String: UUID]

    init(name: String, built: BuiltWorkout) {
        self.name = name
        items = built.items.map(\.exercise)
        listings = built.items.reduce(into: [:]) { result, item in
            if let id = item.match.loadListingId { result[item.exercise.exerciseId] = id }
        }
    }
}

/// One Build workout request and what Rebuild has shown so far. Rebuild adds the current result to `avoid` on every
/// tap, in order, so once everything has been shown the oldest come back first and tapping cycles through all of them.
@MainActor
@Observable
final class BuildRun {
    private let builder: (_ avoid: [String]) -> BuiltWorkout?
    private(set) var built: BuiltWorkout?
    private(set) var avoidIds: [String] = []

    init(builder: @escaping (_ avoid: [String]) -> BuiltWorkout?) {
        self.builder = builder
    }

    var exerciseIds: [String] { built?.items.map(\.exercise.exerciseId) ?? [] }

    func build() {
        avoidIds = []
        built = builder([])
    }

    func rebuild() {
        guard built != nil else { return build() }
        avoidIds += exerciseIds
        built = builder(avoidIds)
    }

    /// After adding equipment the gym can do more: the same request, with nothing avoided.
    func rebuildAfterAddingEquipment() { build() }
}
