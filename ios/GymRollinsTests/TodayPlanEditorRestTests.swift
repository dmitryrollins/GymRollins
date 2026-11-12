import Foundation
import GymCore
import Testing
@testable import GymRollins

/// Today's exercise screen (plan mode) edits the same per-exercise rest as the workout, with today's rest as the
/// default. The day's own rest is no longer set from it, but one already stored is still read.
@MainActor
@Suite struct TodayPlanEditorRestTests {
    private let day = "2026-09-29"
    private let bench = RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, repsMin: 8)
    private let fly = RoutineExercise(exerciseId: "0319", sets: 3, reps: 12)

    final class Rests {
        var custom: [String: Int] = [:]
        var saved: [(id: String, seconds: Int, defaultSec: Int)] = []
    }

    private func editor(_ rests: Rests, defaultRestSec: Int = 90) -> TodayPlanEditor {
        let routine = Routine(name: "Push", exercises: [bench, fly])
        let editor = TodayPlanEditor(store: nil, defaultRestSec: defaultRestSec,
                                     workingRest: { rests.custom[$0] ?? $1 },
                                     saveWorkingRest: { id, seconds, defaultSec in
                                         rests.saved.append((id, seconds, defaultSec))
                                         rests.custom[id] = seconds
                                     })
        editor.load(TodayPlan.make(scheduled: routine, routines: [routine], lastDone: [:], day: day))
        return editor
    }

    @Test func eachItemRestsItsExercisesTime() {
        let rests = Rests()
        rests.custom = ["0025": 210]
        let editor = editor(rests)
        #expect(editor.workingRest(itemId: bench.id) == 210)
        #expect(editor.workingRest(itemId: fly.id) == 90, "today's rest is the default")
        #expect(editor.workingRest(itemId: UUID()) == 90)
    }

    @Test func settingOneItemsRestKeepsTheDayAndTheOtherItems() {
        let rests = Rests()
        let editor = editor(rests)
        editor.setWorkingRest(150, itemId: bench.id)
        #expect(editor.workingRest(itemId: bench.id) == 150)
        #expect(editor.workingRest(itemId: fly.id) == 90)
        #expect(editor.plan?.restSec == nil, "the day's rest isn't set any more")
        #expect(rests.saved.first?.id == "0025")
        #expect(rests.saved.first?.defaultSec == 90)
    }

    @Test func aStoredDayRestIsStillTheDefault() throws {
        let rests = Rests()
        let editor = editor(rests)
        editor.apply(try #require(editor.plan).withRest(150)) // stored before plan 36
        #expect(editor.workingRest(itemId: fly.id) == 150)
        editor.setWorkingRest(200, itemId: fly.id)
        #expect(rests.saved.first?.defaultSec == 150)
    }

    @Test func aLockedEditorSavesNoRest() {
        let rests = Rests()
        let editor = editor(rests)
        editor.isLocked = true
        editor.setWorkingRest(150, itemId: bench.id)
        #expect(rests.saved.isEmpty)
    }

    @Test func theScreenModelEditsThisExercisesRest() {
        let rests = Rests()
        let editor = editor(rests)
        let model = ExerciseScreenModel.plan(editor, itemId: bench.id)
        model.setRestSeconds(240)
        #expect(model.restSeconds == 240)
        #expect(model.defaultRestSeconds == 90)
        #expect(ExerciseScreenModel.plan(editor, itemId: fly.id).restSeconds == 90)
        #expect(editor.plan?.restSec == nil)
    }

    @Test func workingRestOffersHalfAMinuteToFifteenMinutes() {
        let options = RestSettingsSheet.options(in: RestSettingsSheet.workingRange, including: 95)
        #expect(options.first == 30)
        #expect(options.last == 900)
        #expect(options.contains(95), "a stored value off the 15 s grid still has a row")
        #expect(RestSettingsSheet.options(in: RestSettingsSheet.workingRange, including: 180).count == 59)
        #expect(RestSettingsSheet.options(in: RestSettingsSheet.warmupRange, including: 90).count == 19,
                "warm-ups keep 0:30 to 5:00")
    }
}
