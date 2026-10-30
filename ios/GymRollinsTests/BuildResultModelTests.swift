import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// What the Build result screen says: title, banners and each row's words, from a hand-made `BuiltWorkout`.
@Suite struct BuildResultModelTests {
    private static let exercises = [
        Exercise(id: "kb-row", name: "kettlebell row", bodyPart: "back", equipment: "kettlebell", target: "upper back"),
        Exercise(id: "kb-curl", name: "kettlebell curl", bodyPart: "upper arms", equipment: "kettlebell", target: "biceps"),
        Exercise(id: "pullover", name: "bench pullover", bodyPart: "back", equipment: "kettlebell", target: "lats"),
        Exercise(id: "pushup", name: "push-up", bodyPart: "chest", equipment: "body weight", target: "pectorals"),
    ]
    private static let kinds = [
        EquipmentKind(id: "kettlebells", name: "Kettlebells", category: .freeWeight, load: .fixedSet),
        EquipmentKind(id: "flat-bench", name: "Flat bench", category: .bench, load: .none),
    ]
    private static let requirements = ExerciseRequirements(groups: [
        "kb-row": [["kettlebells"]], "kb-curl": [["kettlebells"]], "pullover": [["flat-bench"]], "pushup": [],
    ])
    /// The 44 and 53 lb bells as an lb user's chips store them.
    private static let bellChips = ListingLoadsEditing(kind: kinds[0], unit: .lb, loads: .none).options
        .filter { ["44 lb (20 kg)", "53 lb (24 kg)"].contains($0.label) }
    private let bells = InventoryListing(id: UUID(), kindId: "kettlebells",
                                         loads: .fixed(kg: BuildResultModelTests.bellChips.map(\.kg)))
    private let bench = InventoryListing(id: UUID(), kindId: "flat-bench")
    private let library = ExerciseLibrary(exercises: Self.exercises)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private var gym: TodayGymContext {
        let matcher = InventoryMatcher(requirements: Self.requirements, kinds: Self.kinds,
                                       inventory: GymInventory(gymName: "Home", listings: [bells, bench]))
        return TodayGymContext(matcher: matcher, photo: { [bells] in $0 == bells.id ? "bells.jpg" : nil })
    }

    private func item(_ id: String, weightKg: Double? = nil, muscle: BuildMuscle = .back, repeatOf: Date? = nil,
                      fill: Bool = false, reps: Int = 10) -> BuiltItem {
        let match: InventoryMatch
        switch id {
        case "pullover": match = InventoryMatch(listingIds: [bench.id], loadListingId: nil)
        case "pushup": match = .noEquipment
        default: match = InventoryMatch(listingIds: [bells.id], loadListingId: bells.id)
        }
        return BuiltItem(exercise: RoutineExercise(exerciseId: id, sets: 3, reps: reps, weightKg: weightKg),
                         match: match, muscle: muscle, repeatOf: repeatOf, isBodyweightFill: fill)
    }

    private func make(_ items: [BuiltItem], muscles: [BuildMuscle] = [.back, .arms], length: BuildLength = .medium,
                      thin: [ThinInventoryNotice] = [], slots: Int? = nil, skipped: [BuildMuscle] = []) -> BuildResultModel {
        let built = BuiltWorkout(items: items, thin: thin, requestedSlots: slots ?? items.count, skipped: skipped)
        return BuildResultModel.make(built: built, muscles: muscles, length: length, gymName: "Home", gym: gym,
                                     profile: Profile(), library: library, history: { _ in [] }, calendar: calendar)
    }

    @Test func titleJoinsChips() {
        #expect(make([item("kb-row")], muscles: [.back, .arms]).title == "Back + Arms")
        #expect(make([item("kb-row")], muscles: [.chest]).title == "Chest")
    }

    @Test func subtitleCountsAndMinutes() {
        let four = make([item("kb-row"), item("kb-curl"), item("pullover"), item("pushup", fill: true)])
        #expect(four.subtitle == "Home \u{00B7} 4 exercises \u{00B7} ~45 min")
        #expect(make([item("kb-row")], length: .short).subtitle == "Home \u{00B7} 1 exercise \u{00B7} ~30 min")
    }

    /// The set's 50 lb isn't a bell: the row shows the 53 lb bell it is fitted to.
    @Test func rowShowsSetsRepsAndFittedLoad() throws {
        let row = try #require(make([item("kb-row", weightKg: UnitConverter.toKg(50, from: .lb))]).rows.first)
        #expect(row.subtitle == "3 \u{00D7} 10 \u{00B7} 53 lb (24 kg)", "was \(row.subtitle)")
        #expect(row.name == DisplayName.of("kettlebell row"))
    }

    /// The chip that stored the bell and the row that shows it say the same thing.
    @Test func rowAndChipAgreeOnTheBell() throws {
        #expect(Self.bellChips.count == 2)
        let chip = try #require(Self.bellChips.first { $0.label == "53 lb (24 kg)" })
        let row = try #require(make([item("kb-row", weightKg: UnitConverter.toKg(53, from: .lb))]).rows.first)
        #expect(row.subtitle.hasSuffix(chip.label), "was \(row.subtitle)")
        #expect(!row.subtitle.contains("+"), "no extra reps: the weight didn't rise")
        #expect(row.subtitle.hasPrefix("3 \u{00D7} 10"), "was \(row.subtitle)")
    }

    /// Past the heaviest bell the workout starts with more reps, and the row says so, like Today's row does.
    @Test func rowShowsTheRaisedRepsPastTheHeaviestWeight() throws {
        let history = [SessionResult(date: .now, weightKg: 30, reps: [10, 10, 10])]
        let built = BuiltWorkout(items: [item("kb-curl")], thin: [], requestedSlots: 1, skipped: [])
        let model = BuildResultModel.make(built: built, muscles: [.arms], length: .short, gymName: "Home", gym: gym,
                                          profile: Profile(), library: library, history: { _ in history }, calendar: calendar)
        let planned = built.items[0].exercise
        let entry = SessionPlanner.entry(for: planned, policy: .double, profile: Profile(), exercise: library.exercise("kb-curl"),
                                         history: history, loads: gym.loads(for: "kb-curl"))
        let reps = try #require(entry.sets.first?.reps)
        #expect(reps > 10)
        #expect(model.rows.first?.subtitle.hasPrefix("3 \u{00D7} \(reps) \u{00B7}") == true, "was \(model.rows.first?.subtitle ?? "")")
    }

    @Test func rowNamesItsListing() throws {
        let rows = make([item("kb-row"), item("pullover"), item("pushup", fill: true)]).rows
        #expect(rows[0].listingName == "Kettlebells")
        #expect(rows[0].photoFile == "bells.jpg")
        #expect(rows[1].listingName == "Flat bench")
        #expect(rows[1].photoFile == nil, "no photo: the exercise thumbnail shows")
        #expect(rows[2].listingName == nil)
    }

    @Test func repeatRowHasBadgeAndReason() throws {
        let day = try #require(ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z"))
        let rows = make([item("kb-row", repeatOf: day), item("kb-curl")]).rows
        #expect(rows[0].mark == .repeated)
        #expect(rows[0].reason == "also Tuesday \u{00B7} no other Back option here")
        #expect(rows[1].mark == nil)
        #expect(rows[1].reason == nil)
    }

    @Test func bodyweightFillIsMarked() throws {
        let row = try #require(make([item("pushup", muscle: .chest, fill: true)], muscles: [.chest]).rows.first)
        #expect(row.mark == .noEquipment)
        #expect(BuildResultModel.Mark.noEquipment.text == "no equipment")
        #expect(BuildResultModel.Mark.repeated.text == "REPEAT")
    }

    @Test func thinNoticeWords() {
        let model = make([item("kb-row")], thin: [ThinInventoryNotice(muscle: .back, itemCount: 3)])
        #expect(model.thinNotices == ["Only 3 Back items catalogued at Home so far. Add a photo to unlock more variety."])
        let one = make([item("kb-row")], thin: [ThinInventoryNotice(muscle: .arms, itemCount: 1)])
        #expect(one.thinNotices == ["Only 1 Arms item catalogued at Home so far. Add a photo to unlock more variety."])
    }

    @Test func thinNoticeWithNoItems() {
        let model = make([item("kb-row")], thin: [ThinInventoryNotice(muscle: .back, itemCount: 0)])
        #expect(model.thinNotices == ["No Back equipment catalogued at Home yet. Add a photo to unlock more variety."])
    }

    @Test func skippedChipsAreReported() {
        let model = make([item("kb-row")], muscles: [.back, .arms, .core], length: .short, skipped: [.core])
        #expect(model.skippedNotice == "No room for Core at 30 min")
        #expect(model.title == "Back + Arms", "the name lists only the chips that got exercises")
        let two = make([item("kb-row")], muscles: [.back, .arms, .core, .legs], length: .short, skipped: [.core, .legs])
        #expect(two.skippedNotice == "No room for Core, Legs at 30 min")
        #expect(two.title == "Back + Arms")
        #expect(make([item("kb-row")]).skippedNotice == nil)
    }

    @Test func shortWorkoutSaysSo() {
        let model = make([item("kb-row"), item("kb-curl"), item("pullover"), item("pushup", fill: true)],
                         length: .long, slots: 6)
        #expect(model.shortNotice == "4 of 6 exercises. That's all this gym has for these muscles right now.")
        #expect(make([item("kb-row")], slots: 1).shortNotice == nil)
    }

    @Test func nothingFitsIsAnEmptyResult() {
        let model = make([], thin: [ThinInventoryNotice(muscle: .back, itemCount: 0)], slots: 4)
        #expect(model.isEmpty)
        #expect(model.shortNotice == nil, "the empty state speaks for itself")
        #expect(model.thinNotices.count == 1)
    }

    // MARK: Rebuild

    @MainActor
    @Test func rebuildAppendsTheResultInOrderAndAddingEquipmentStartsOver() {
        var asked: [[String]] = []
        var next = 0
        let run = BuildRun { avoid in
            asked.append(avoid)
            next += 1
            let ids = ["a\(next)", "b\(next)"]
            return BuiltWorkout(items: ids.map { BuiltItem(exercise: RoutineExercise(exerciseId: $0, sets: 3, reps: 10),
                                                           match: .noEquipment, muscle: .back) },
                                thin: [], requestedSlots: 2, skipped: [])
        }
        run.build()
        run.rebuild()
        run.rebuild()
        run.rebuild()
        #expect(asked == [[], ["a1", "b1"], ["a1", "b1", "a2", "b2"], ["a1", "b1", "a2", "b2", "a3", "b3"]])
        run.rebuildAfterAddingEquipment()
        #expect(asked.last == [], "adding equipment asks again with nothing to avoid")
        run.rebuild()
        #expect(asked.last == ["a5", "b5"], "and the next Rebuild starts the list again from the new result")
    }
}
