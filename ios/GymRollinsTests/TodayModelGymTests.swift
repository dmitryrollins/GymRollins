import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// What Today's rows say about the current gym, and that the row shows what Start will really do.
@Suite struct TodayModelGymTests {
    private static let exercises = [
        Exercise(id: "preacher", name: "preacher curl", bodyPart: "upper arms", equipment: "barbell", target: "biceps"),
        Exercise(id: "kb-curl", name: "kettlebell curl", bodyPart: "upper arms", equipment: "kettlebell", target: "biceps"),
        Exercise(id: "bb-row", name: "barbell row", bodyPart: "back", equipment: "barbell", target: "upper back"),
        Exercise(id: "kb-press", name: "kettlebell press", bodyPart: "chest", equipment: "kettlebell", target: "pectorals"),
        Exercise(id: "unknown", name: "mystery move", bodyPart: "chest", equipment: "other", target: "pectorals"),
    ]
    private static let requirements = ExerciseRequirements(groups: [
        "preacher": [["preacher-bench"]], "kb-curl": [["kettlebells"]], "bb-row": [["barbell"]],
        "kb-press": [["kettlebells"], ["flat-bench"]],
    ])
    private static let kinds = [
        EquipmentKind(id: "preacher-bench", name: "Preacher bench", category: .bench, load: .none),
        EquipmentKind(id: "kettlebells", name: "Kettlebells", category: .freeWeight, load: .fixedSet),
        EquipmentKind(id: "flat-bench", name: "Flat bench", category: .bench, load: .none),
        EquipmentKind(id: "barbell", name: "Barbell", category: .freeWeight, load: .plateLoaded),
    ]
    private let bells = InventoryListing(id: UUID(), kindId: "kettlebells", loads: .fixed(kg: [20, 24]))
    private let bench = InventoryListing(id: UUID(), kindId: "flat-bench")
    private let library = ExerciseLibrary(exercises: Self.exercises)

    private var matcher: InventoryMatcher {
        InventoryMatcher(requirements: Self.requirements, kinds: Self.kinds,
                         inventory: GymInventory(gymName: "Home", listings: [bells, bench]))
    }

    private func item(_ id: String, reps: Int = 10, repsMin: Int? = nil) -> RoutineExercise {
        RoutineExercise(exerciseId: id, sets: 3, reps: reps, repsMin: repsMin)
    }

    private func model(_ items: [RoutineExercise], history: [String: [SessionResult]] = [:],
                       photos: [UUID: String] = [:], change: (TodayPlan) -> TodayPlan = { $0 }) -> TodayModel {
        let routine = Routine(name: "Arms", exercises: items)
        let adapter = GymAdapter(matcher: matcher, exercises: Self.exercises)
        let plan = change(TodayPlan.make(scheduled: routine, routines: [routine], lastDone: [:], day: "d").adapted(by: adapter))
        let context = TodayGymContext(matcher: matcher, photo: { photos[$0] })
        return TodayModel.make(plan: plan, profile: Profile(), library: library, history: { history[$0] ?? [] },
                               gym: context, loads: context.loads(for:))
    }

    @Test func swappedRowSaysWhatItReplacesAndWhy() throws {
        let row = try #require(model([item("preacher")]).rows.first)
        #expect(row.exerciseId == "kb-curl")
        #expect(row.gymMark == .swapped(planned: DisplayName.of("preacher curl"), missingKind: "preacher bench"))
    }

    @Test func noteCountsTheSwaps() {
        #expect(model([item("preacher")]).gymNote == "1 exercise swapped for this gym. Your plan isn't changed.")
        #expect(model([item("kb-curl")]).gymNote == nil)
        let two = TodayModel.make(
            plan: TodayPlan(day: "d", kind: .scheduled, base: nil, exercises: [item("kb-curl"), item("kb-press")], edited: false,
                            gymSwaps: [UUID(): item("preacher"), UUID(): item("bb-row")]),
            profile: Profile(), library: library, history: { _ in [] })
        #expect(two.gymNote == "2 exercises swapped for this gym. Your plan isn't changed.")
    }

    @Test func rowWithNothingSimilarIsMarkedUnavailable() throws {
        let row = try #require(model([item("bb-row")]).rows.first)
        #expect(row.exerciseId == "bb-row")
        #expect(row.gymMark == .unavailable(missingKind: "barbell"))
    }

    @Test func aPinnedRowIsNeverMarked() throws {
        let planned = item("bb-row")
        let row = try #require(model([planned]) { $0.replacing(planned.id, with: planned) }.rows.first)
        #expect(row.exerciseId == "bb-row")
        #expect(row.gymMark == nil)
    }

    @Test func anUnmappedRowIsUnmarked() throws {
        let row = try #require(model([item("unknown")]).rows.first)
        #expect(row.gymMark == nil)
        #expect(row.photoFile == nil)
    }

    @Test func keptRowShowsItsListingsPhotoLoadListingFirst() throws {
        let both = try #require(model([item("kb-press")], photos: [bells.id: "bells.jpg", bench.id: "bench.jpg"]).rows.first)
        #expect(both.photoFile == "bells.jpg")
        #expect(both.gymMark == nil)
        let benchOnly = try #require(model([item("kb-press")], photos: [bench.id: "bench.jpg"]).rows.first)
        #expect(benchOnly.photoFile == "bench.jpg")
        let none = try #require(model([item("kb-press")]).rows.first)
        #expect(none.photoFile == nil)
    }

    @Test func withNoGymNothingDiffers() {
        let routine = Routine(name: "Arms", exercises: [item("preacher"), item("kb-curl")])
        let plain = TodayPlan.make(scheduled: routine, routines: [routine], lastDone: [:], day: "d")
        let model = TodayModel.make(plan: plain, profile: Profile(), library: library, history: { _ in [] })
        #expect(model.gymNote == nil)
        #expect(model.rows.allSatisfy { $0.gymMark == nil && $0.photoFile == nil })
        #expect(model.rows.map(\.exerciseId) == ["preacher", "kb-curl"])
    }

    /// The row must say what Start will do: past the heaviest bell the reps go up, and the exercise screen and the
    /// workout use the raised number.
    @Test func rowShowsTheRaisedRepsAtTheHeaviestWeight() throws {
        let planned = item("kb-curl", reps: 10, repsMin: 8)
        let history = ["kb-curl": [SessionResult(date: .now, weightKg: 30, reps: [10, 10, 10])]]
        let row = try #require(model([planned], history: history).rows.first)
        let entry = SessionPlanner.entry(for: planned, policy: .double, profile: Profile(),
                                         exercise: library.exercise("kb-curl"), history: history["kb-curl"] ?? [],
                                         loads: .fixed(kg: [20, 24]))
        let reps = try #require(entry.sets.first?.reps)
        #expect(entry.sets.first?.weightKg == 24)
        #expect(row.suggestedKg == 24)
        #expect(row.subtitle.hasPrefix("3 \u{00D7} \(reps) \u{00B7}"), "was \(row.subtitle)")
    }

    @Test func rowKeepsTheRepRangeWhenTheWeightFits() throws {
        let planned = item("kb-curl", reps: 10, repsMin: 8)
        let history = ["kb-curl": [SessionResult(date: .now, weightKg: 20, reps: [8, 8, 8])]]
        let row = try #require(model([planned], history: history).rows.first)
        #expect(row.subtitle.hasPrefix("3 \u{00D7} 8\u{2013}10 \u{00B7}"), "was \(row.subtitle)")
    }

    @Test func builtPlanNamesItself() {
        let built = TodayPlan.built(name: "Back + Arms", items: [item("kb-curl"), item("kb-press")], day: "d")
        let model = TodayModel.make(plan: built, profile: Profile(), library: library, history: { _ in [] })
        #expect(model.title == "Back + Arms")
        #expect(model.summary == "2 exercises")
    }
}
