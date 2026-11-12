import Foundation
import GymCore
import Testing
@testable import GymRollins

/// Typing in a set's box on the exercise screen (`SetEdit` through `ExerciseScreenModel.type`): every keystroke writes
/// the edited set and the later sets still to do that showed the same text, worked out from the sets as they were
/// before the first keystroke, in one save.
@MainActor
@Suite struct SetEditSessionTests {
    private final class Saves { var count = 0 }

    private func make(_ sets: [WorkoutSet], saves: Saves = Saves()) -> WorkoutSession {
        let workout = Workout(startedAt: Date(timeIntervalSince1970: 1_000), name: "Home",
                              entries: [WorkoutEntry(exerciseId: "0541", sets: sets)])
        return WorkoutSession(
            workout: workout, clock: WorkoutClock(startedAt: workout.startedAt),
            restSeconds: 90, warmupRestSeconds: 60, notifier: NoopRestNotifier(),
            now: { Date(timeIntervalSince1970: 1_100) },
            persist: { _, _ in saves.count += 1 }, previousBests: { _ in nil }, saveFinished: { _, _ in },
            discard: {})
    }

    private func model(_ s: WorkoutSession) -> ExerciseScreenModel { .workout(s, entryId: s.workout.entries[0].id) }
    private func sets(_ s: WorkoutSession) -> [WorkoutSet] { s.workout.entries[0].sets }
    private func reps(_ s: WorkoutSession) -> [Int] { sets(s).map(\.reps) }
    private func weights(_ s: WorkoutSession) -> [Double] { sets(s).map(\.weightKg) }

    /// Types each text in turn into one box, as the screen does; leaving the box ends the edit (the returned one).
    @discardableResult
    private func type(_ texts: [String], in field: SetField, _ model: ExerciseScreenModel,
                      unit: WeightUnit = .kg) -> SetEdit? {
        texts.reduce(nil) { edit, text in model.type(text, in: field, continuing: edit, unit: unit) }
    }

    private func reps(_ values: [Int]) -> [WorkoutSet] { values.map { WorkoutSet(weightKg: 20, reps: $0) } }

    @Test func aNewWeightCarriesToTheSetsStillToDo() {
        let s = make([WorkoutSet(weightKg: 20.4, reps: 12, done: true), WorkoutSet(weightKg: 20.4, reps: 12),
                      WorkoutSet(weightKg: 20.4, reps: 12), WorkoutSet(weightKg: 20.4, reps: 12)])
        type(["2", "24"], in: .weight(sets(s)[1].id), model(s))
        #expect(weights(s) == [20.4, 24, 24, 24])
    }

    @Test func handChangedSetsStopTheCarry() {
        let s = make([WorkoutSet(weightKg: 20, reps: 10), WorkoutSet(weightKg: 22, reps: 10),
                      WorkoutSet(weightKg: 20, reps: 10)])
        type(["2", "25"], in: .weight(sets(s)[0].id), model(s))
        #expect(weights(s) == [25, 22, 20]) // set 2 was changed by hand: the carry stops there
    }

    @Test func newRepsCarryToTheSetsAfter() {
        let s = make(reps([10, 10, 10]))
        type(["1", "12"], in: .reps(sets(s)[1].id), model(s))
        #expect(reps(s) == [10, 12, 12])
        #expect(weights(s) == [20, 20, 20])
    }

    @Test func aClearedBoxPutsTheSetsBack() {
        let s = make(reps([12, 12, 12]))
        let edit = type(["1"], in: .reps(sets(s)[0].id), model(s))
        #expect(reps(s) == [1, 1, 1], "live: the later sets follow while typing")
        _ = model(s).type("", in: .reps(sets(s)[0].id), continuing: edit, unit: .kg) // then the box is left
        #expect(reps(s) == [12, 12, 12])
    }

    @Test func aHandSetLaterSetEqualToATypingPrefixKeepsItsValue() {
        let s = make(reps([10, 10, 1]))
        type(["1", "12"], in: .reps(sets(s)[0].id), model(s))
        #expect(reps(s) == [12, 12, 1])
    }

    @Test func cardioMinutesCarryWithTheirSeconds() throws {
        let s = make((0..<3).map { _ in WorkoutSet(weightKg: 0, reps: 0, sec: 600, minutes: 10) })
        type(["2", "20"], in: .minutes(sets(s)[0].id), model(s))
        #expect(sets(s).map(\.minutes) == [20, 20, 20])
        #expect(sets(s).map(\.sec) == [1_200, 1_200, 1_200])
        #expect(sets(s).map { SetFieldFormat.display(.minutes($0.id), set: $0, unit: .kg) } == ["20", "20", "20"])
    }

    @Test func distanceCarries() {
        let s = make((0..<3).map { _ in WorkoutSet(weightKg: 0, reps: 0, minutes: 10, distanceM: 2_000) })
        type(["2.5"], in: .distance(sets(s)[0].id), model(s))
        #expect(sets(s).map(\.distanceM) == [2_500, 2_500, 2_500])
        #expect(sets(s).map(\.minutes) == [10, 10, 10])
    }

    @Test func editingALoggedSetCarriesNothing() {
        let s = make([WorkoutSet(weightKg: 20, reps: 10, done: true), WorkoutSet(weightKg: 20, reps: 10),
                      WorkoutSet(weightKg: 20, reps: 10)])
        type(["1", "12"], in: .reps(sets(s)[0].id), model(s))
        type(["2", "25"], in: .weight(sets(s)[0].id), model(s))
        #expect(reps(s) == [12, 10, 10])
        #expect(weights(s) == [25, 20, 20], "correcting history doesn't change the plan")
    }

    @Test func setsThatLookTheSameFollowInTheShownUnit() {
        let kg = UnitConverter.toKg(135, from: .lb)
        let s = make([WorkoutSet(weightKg: kg, reps: 8), WorkoutSet(weightKg: kg + 0.004, reps: 8),
                      WorkoutSet(weightKg: kg + 1, reps: 8)])
        type(["15", "150"], in: .weight(sets(s)[0].id), model(s), unit: .lb)
        let target = UnitConverter.toKg(150, from: .lb)
        #expect(weights(s) == [target, target, kg + 1])
    }

    @Test func aKeystrokeIsOneSave() {
        let saves = Saves()
        let s = make(reps([10, 10, 10, 10]), saves: saves)
        let edit = type(["1"], in: .reps(sets(s)[0].id), model(s))
        #expect(reps(s) == [1, 1, 1, 1])
        #expect(saves.count == 1, "the edited set and its three followers in one save")
        _ = model(s).type("1", in: .reps(sets(s)[0].id), continuing: edit, unit: .kg)
        #expect(saves.count == 1, "no change, no save")
    }

    @Test func aSetLoggedMeanwhileStaysLogged() throws {
        let s = make(reps([10, 10, 10]))
        let edit = type(["1"], in: .reps(sets(s)[0].id), model(s))
        let logged = sets(s)[1].id
        s.update(entryId: s.workout.entries[0].id, setId: logged) { $0.completing(at: Date(timeIntervalSince1970: 1_050)) }
        _ = model(s).type("12", in: .reps(sets(s)[0].id), continuing: edit, unit: .kg) // e.g. logged from the watch
        let set = try #require(sets(s).first { $0.id == logged })
        #expect(set.done)
        #expect(reps(s) == [12, 1, 12])
    }

    @Test func planModeTypesTheSameWayInOneSave() throws {
        let store = CountingStore()
        let item = RoutineExercise(exerciseId: "0025", sets: 3, reps: 10)
        let routine = Routine(name: "Push", exercises: [item])
        let editor = TodayPlanEditor(store: store, defaultRestSec: 90) { _, _ in
            (0..<3).map { _ in WorkoutSet(weightKg: 60, reps: 10) }
        }
        editor.load(TodayPlan.make(scheduled: routine, routines: [routine], lastDone: [:], day: "2026-11-12"))
        let model = ExerciseScreenModel.plan(editor, itemId: item.id)
        let first = try #require(model.sets?.first)
        let edit = type(["1"], in: .reps(first.id), model)
        #expect(store.saves == 1)
        _ = model.type("", in: .reps(first.id), continuing: edit, unit: .kg)
        #expect(model.sets?.map(\.reps) == [10, 10, 10])
        type(["1", "12"], in: .reps(first.id), model)
        #expect(model.sets?.map(\.reps) == [12, 12, 12])
    }

    private final class CountingStore: TodayPlanSaving {
        var saves = 0
        func save(_ plan: TodayPlan) { saves += 1 }
        func clear() {}
    }
}
