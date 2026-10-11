import XCTest

final class ShellUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testFourTabsExist() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launch()
        for name in ["Today", "Body", "Library", "Log"] {
            XCTAssertTrue(app.tabBars.buttons[name].waitForExistence(timeout: 5), "missing tab \(name)")
        }
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
    }

    func testTodayShowsSaturdayPushDay() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launch()
        XCTAssertTrue(app.staticTexts["today.summary"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["today.summary"].label, "Push + Arms \u{00B7} 7 exercises")
        XCTAssertTrue(app.buttons["today.start"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["today.row.0025"].exists)
    }

    func testStartWorkoutClosesAndKeepsSessionRunning() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launch()
        app.startWorkout()
        XCTAssertTrue(app.buttons["workout.close"].waitForExistence(timeout: 5))
        app.buttons["workout.close"].tap()
        XCTAssertTrue(app.buttons["today.resume"].waitForExistence(timeout: 5))
    }
}
