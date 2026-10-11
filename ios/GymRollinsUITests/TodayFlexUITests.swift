import XCTest

/// Today can always start a workout: an unplanned day offers the next routine, Switch picks another (or an empty
/// workout), and each exercise's ··· menu / Add Exercise edit today's workout before it starts.
final class TodayFlexUITests: XCTestCase {
    /// A Tuesday: the seeded split trains Mon/Wed/Fri/Sat.
    private let restDay = "2026-09-29T09:00:00Z"

    override func setUp() {
        continueAfterFailure = false
    }

    private func summary(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["today.summary"] }

    private func waitForSummary(_ app: XCUIApplication, containing text: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: summary(app))],
                                      timeout: 5)
        XCTAssertEqual(result, .completed, "summary was '\(summary(app).label)'", file: file, line: line)
    }

    func testRestDayOffersTheNextRoutineAndCanStart() {
        let app = XCUIApplication.launchReady(fixedNow: restDay) { $0.staticTexts["today.summary"] }
        waitForSummary(app, containing: "Rest day \u{00B7} optional")
        let start = app.buttons["today.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.buttons["workout.close"].waitForExistence(timeout: 5), "the workout opened")
    }

    func testSwitchToAnEmptyWorkoutAndAddAnExercise() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        app.buttons["today.switch"].tap()
        let empty = app.buttons["today.switch.empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        empty.tap()
        waitForSummary(app, containing: "Empty workout")
        XCTAssertEqual(app.buttons["today.start"].label, "Start Empty Workout")

        app.buttons["today.addExercise"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("chest dip")
        app.buttons["picker.row.0251"].tap()
        app.navigationBars["Add Exercise"].buttons["Close"].tap()
        app.buttons["picker.add"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["today.row.0251"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["today.start"].label, "Start Workout")
    }

    /// A today plan belongs to the store it was made from: relaunching on a fresh in-memory store (every UI test does)
    /// shows the scheduled routine again, not the previous run's switched workout.
    func testSwitchedPlanDoesNotLeakIntoAFreshLaunch() {
        var app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        app.buttons["today.switch"].tap()
        let empty = app.buttons["today.switch.empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        empty.tap()
        waitForSummary(app, containing: "Empty workout")
        app.terminate()

        app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        XCTAssertTrue(app.descendants(matching: .any)["today.row.0025"].waitForExistence(timeout: 5))
        XCTAssertFalse(summary(app).label.contains("Empty workout"), summary(app).label)
    }

    func testRowMenuDeletesForTodayAndSavesToTheRoutine() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        let row = app.descendants(matching: .any)["today.row.0025"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.buttons["today.row.menu.0025"].tap()
        let delete = app.buttons["Delete from Workout"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        waitForSummary(app, containing: "edited for today")

        let save = app.buttons["today.saveToRoutine"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5), "saved: nothing left to save")
        XCTAssertFalse(summary(app).label.contains("edited"), summary(app).label)
        XCTAssertFalse(row.exists, "the routine itself no longer has it")
    }

    func testRowMenuOpensInstructions() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        app.buttons["today.row.menu.0025"].tap()
        let instructions = app.buttons["Video & Instructions"]
        XCTAssertTrue(instructions.waitForExistence(timeout: 5))
        instructions.tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
    }
}
