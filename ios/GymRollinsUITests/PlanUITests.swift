import XCTest

final class PlanUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launch()
        app.buttons["today.myPlan"].tap()
    }

    func testPlanShowsWeekAndRoutines() {
        XCTAssertTrue(app.buttons["plan.routine.Push + Arms"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["plan.routine.Legs"].exists)
        XCTAssertTrue(app.staticTexts["Paused"].exists)
    }

    func testEditRoutineAddsExerciseAndChangesSets() {
        app.buttons["plan.routine.Push + Arms"].tap()
        let sets = app.steppers["edit.sets.0025"]
        XCTAssertTrue(sets.waitForExistence(timeout: 5))
        // A Stepper with an explicit accessibilityIdentifier exposes its sub-buttons suffixed
        // with that identifier ("edit.sets.0025-Increment"), not the plain "Increment" label
        // (confirmed via an accessibility hierarchy dump).
        sets.buttons["edit.sets.0025-Increment"].tap()
        // The exercise List only realizes rows near the visible viewport, so "+ Add exercise"
        // (after all 7 rows) needs to be scrolled into view before it exists in the hierarchy.
        let addExercise = app.buttons["edit.addExercise"]
        scrollUntilExists(addExercise)
        addExercise.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("chest dip")
        app.buttons["picker.row.0251"].tap()
        // While the search field is actively focused/searching, SwiftUI's .searchable
        // suppresses the toolbar's Cancel/Add items in favor of only its own search-session
        // "Close" button; tapping it ends the search session and restores our toolbar so
        // "picker.add" becomes reachable again (confirmed via an accessibility hierarchy dump).
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
