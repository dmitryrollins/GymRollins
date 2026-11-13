import XCTest

/// My Plan is the week (owner, 2026-11-10): a row per day, tap a day to change it, and Saved workouts for the rest.
/// The seed: Push + Arms on Monday and Saturday (today), Pull on Wednesday, Upper weak points on Friday, Legs paused.
final class PlanUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication.launchReady { $0.buttons["today.myPlan"] }
        app.buttons["today.myPlan"].tap()
        XCTAssertTrue(app.buttons["plan.day.1"].waitForExistence(timeout: 5))
    }

    private func day(_ weekday: Int) -> XCUIElement { app.buttons["plan.day.\(weekday)"] }

    func testTheWeekShowsEachDaysWorkout() {
        XCTAssertTrue(day(1).label.contains("Monday"), day(1).label)
        XCTAssertTrue(day(1).label.contains("Push + Arms"), day(1).label)
        XCTAssertTrue(day(2).label.contains("Rest"), day(2).label)
        XCTAssertTrue(day(3).label.contains("Pull"), day(3).label)
        XCTAssertTrue(day(6).label.contains("Today"), day(6).label)
    }

    func testOnlyMondayGivesMondayItsOwnCopy() {
        day(1).tap()
        let sets = app.steppers["edit.sets.0025"]
        XCTAssertTrue(sets.waitForExistence(timeout: 5))
        sets.buttons["edit.sets.0025-Increment"].tap()
        app.buttons["edit.done"].tap()
        let only = app.buttons["Only Monday"]
        XCTAssertTrue(only.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Change Monday and Saturday"].exists)
        only.tap()
        XCTAssertTrue(day(1).waitForExistence(timeout: 5))
        let mondayCopy = NSPredicate(format: "label CONTAINS %@", "Push + Arms (Mon)")
        wait(for: [expectation(for: mondayCopy, evaluatedWith: day(1))], timeout: 5)
        XCTAssertFalse(day(6).label.contains("(Mon)"), day(6).label)
    }

    func testChangingBothDaysEditsTheWorkout() {
        day(1).tap()
        let sets = app.steppers["edit.sets.0025"]
        XCTAssertTrue(sets.waitForExistence(timeout: 5))
        sets.buttons["edit.sets.0025-Increment"].tap()
        app.buttons["edit.done"].tap()
        let both = app.buttons["Change Monday and Saturday"]
        XCTAssertTrue(both.waitForExistence(timeout: 5))
        both.tap()
        day(6).tap()
        XCTAssertTrue(app.staticTexts["4 sets"].waitForExistence(timeout: 5), "Saturday has the change too")
    }

    func testARestDayGetsASavedWorkout() {
        day(2).tap()
        let picker = app.buttons["day.workout"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Pull + Shoulders + Triceps"].tap()
        XCTAssertTrue(app.steppers.firstMatch.waitForExistence(timeout: 5), "its exercises show")
        app.buttons["edit.done"].tap()
        let pull = NSPredicate(format: "label CONTAINS %@", "Pull")
        wait(for: [expectation(for: pull, evaluatedWith: day(2))], timeout: 5)
    }

    func testSavedWorkoutsListsEveryWorkoutAndEditsOne() {
        let saved = app.buttons["plan.savedWorkouts"]
        app.scrollToHittable(saved)
        saved.tap()
        XCTAssertTrue(app.buttons["plan.routine.Push + Arms"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["plan.routine.Legs"].exists)
        XCTAssertTrue(app.staticTexts["Paused"].exists)

        app.buttons["plan.routine.Push + Arms"].tap()
        let sets = app.steppers["edit.sets.0025"]
        XCTAssertTrue(sets.waitForExistence(timeout: 5))
        // A Stepper with an explicit accessibilityIdentifier exposes its sub-buttons suffixed with that identifier.
        sets.buttons["edit.sets.0025-Increment"].tap()
        // The exercise List only realizes rows near the viewport, so "+ Add exercise" must be scrolled into view.
        let addExercise = app.buttons["edit.addExercise"]
        scrollUntilExists(addExercise)
        addExercise.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("chest dip")
        app.buttons["picker.row.0251"].tap()
        // While searching, .searchable hides the toolbar; Close ends the search so "picker.add" is reachable.
        app.buttons["Close"].tap()
        app.buttons["picker.add"].tap()
        let newRow = app.descendants(matching: .any)["edit.row.0251"]
        scrollUntilExists(newRow)
        XCTAssertTrue(newRow.exists)
        app.buttons["edit.done"].tap()
        app.buttons["plan.routine.Push + Arms"].tap()
        XCTAssertTrue(app.staticTexts["4 sets"].waitForExistence(timeout: 5))
    }

    /// Swipes up on the app to bring a lazily-realized List row into the accessibility tree.
    private func scrollUntilExists(_ element: XCUIElement, maxSwipes: Int = 12) {
        var attempts = 0
        while !element.exists && attempts < maxSwipes {
            app.swipeUp()
            attempts += 1
        }
    }
}
