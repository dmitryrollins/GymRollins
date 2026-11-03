import Foundation
import Testing
@testable import GymRollins

private func instant(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

@Suite struct LimitsCheckInModelTests {
    let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    let until = instant("2026-10-26T00:00:00Z")
    let legs = LimitsCheckInModel.PausedRoutine(id: UUID(), name: "Legs")
    let core = LimitsCheckInModel.PausedRoutine(id: UUID(), name: "Core")

    @Test func theReminderAddsTheDateWhenThereIsOne() {
        #expect(LimitsCheckInModel.reminder(note: "Knee", until: nil, calendar: utc) == "Knee")
        #expect(LimitsCheckInModel.reminder(note: "Knee", until: until, calendar: utc)
                == "Knee \u{00B7} until \(GoalDate.dayMonth(until, calendar: utc))")
    }

    @Test func theQuestionNamesTheDate() {
        #expect(LimitsCheckInModel.question(until: until, calendar: utc)
                == "You planned this until \(GoalDate.dayMonth(until, calendar: utc)). Is it the right time to continue?")
    }

    @Test func theResumedMessageCountsWhatWasLowered() {
        #expect(LimitsCheckInModel.resumedMessage(name: "Legs", lowered: 6)
                == "Legs is back, with 6 exercises at 60%. Pick its day in My Plan.")
        #expect(LimitsCheckInModel.resumedMessage(name: "Legs", lowered: 1)
                == "Legs is back, with 1 exercise at 60%. Pick its day in My Plan.")
        #expect(LimitsCheckInModel.resumedMessage(name: "Legs", lowered: 0) == "Legs is back. Pick its day in My Plan.")
    }

    @Test func notYetOffersTwoWeeksAndCancelGoesBack() {
        var model = LimitsCheckInModel()
        model.askLater(now: instant("2026-11-01T09:00:00Z"), calendar: utc)
        #expect(model.step == .choosingDate)
        #expect(model.nextDate == instant("2026-11-15T00:00:00Z"))
        model.cancelLater()
        #expect(model.step == .asking)
    }

    @Test func yesWithNoPausedRoutineCloses() {
        var model = LimitsCheckInModel()
        model.cleared(paused: [])
        #expect(model.step == .done)
    }

    @Test func yesListsThePausedRoutinesAndResumingOneSaysSo() {
        var model = LimitsCheckInModel()
        model.cleared(paused: [legs, core])
        #expect(model.step == .resuming)
        #expect(model.paused == [legs, core])
        model.resumed(legs.id, name: "Legs", lowered: 6)
        #expect(model.step == .resumed("Legs is back, with 6 exercises at 60%. Pick its day in My Plan."))
        #expect(model.paused == [core])
    }

    @Test func aRoutineThatsGoneLeavesTheList() {
        var model = LimitsCheckInModel()
        model.cleared(paused: [legs])
        model.dropped(legs.id)
        #expect(model.paused.isEmpty)
        #expect(model.step == .done)
    }

    @Test func aFailureKeepsTheStepAndShowsTheMessage() {
        var model = LimitsCheckInModel()
        model.cleared(paused: [legs])
        model.failed(LimitsCheckInModel.resumeFailed("Legs"))
        #expect(model.step == .resuming)
        #expect(model.error == "Couldn't bring Legs back. Try again.")
        model.resumed(legs.id, name: "Legs", lowered: 6)
        #expect(model.error == nil)
    }

    @Test func theCardShowsWhenDueWithNoWorkoutAndStaysAfterYes() {
        var model = LimitsCheckInModel()
        #expect(model.showsCard(due: true, workoutRunning: false))
        #expect(!model.showsCard(due: true, workoutRunning: true))
        #expect(!model.showsCard(due: false, workoutRunning: false))
        model.cleared(paused: [legs])
        #expect(model.showsCard(due: false, workoutRunning: false))
        model.close()
        #expect(!model.showsCard(due: true, workoutRunning: false))
    }
}
