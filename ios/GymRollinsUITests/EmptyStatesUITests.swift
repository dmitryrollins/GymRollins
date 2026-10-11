import XCTest

/// First-run empty states (plan 07 Task 5), launched with `-emptyStore` (no seeding at all).
final class EmptyStatesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipOnboarding", "-emptyStore", "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launch()
    }

    func testTodayEmptyPlanStateOffersCreateRoutine() {
        XCTAssertTrue(app.staticTexts["today.empty.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["today.empty.title"].label, "No plan yet")
        app.buttons["today.empty.createRoutine"].tap()
        XCTAssertTrue(app.textFields["edit.name"].waitForExistence(timeout: 5))
    }

    func testTodayEmptyPlanStateOffersAskClaude() {
        XCTAssertTrue(app.staticTexts["today.empty.title"].waitForExistence(timeout: 5))
        app.buttons["today.empty.askClaude"].tap()
        XCTAssertTrue(app.staticTexts["today.askClaude.prompt"].waitForExistence(timeout: 5))
        app.buttons["today.askClaude.open"].tap()
        XCTAssertTrue(app.staticTexts["claude.status"].waitForExistence(timeout: 5))
    }

    func testLogEmptyStateOffersStartWorkoutAndImport() {
        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.staticTexts["log.empty.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["log.empty.title"].label, "No workouts yet")
        app.buttons["log.empty.startWorkout"].tap()
        XCTAssertTrue(app.staticTexts["workout.clock"].waitForExistence(timeout: 5))
    }

    /// Closing an in-progress first workout leaves Log empty (active workouts aren't listed); the
    /// empty state must resume that workout, never start a new one over it (which lost its sets).
    func testLogEmptyStateResumesInProgressWorkout() {
        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.buttons["log.empty.startWorkout"].waitForExistence(timeout: 5))
        app.buttons["log.empty.startWorkout"].tap()
        XCTAssertTrue(app.buttons["workout.addExercise"].waitForExistence(timeout: 5))
        app.buttons["workout.addExercise"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("chest dip")
        app.buttons["picker.row.0251"].tap()
        app.navigationBars["Add Exercise"].buttons["Close"].tap()
        app.buttons["picker.add"].tap()
        XCTAssertTrue(app.buttons["workout.entry.0251"].waitForExistence(timeout: 3))
        app.buttons["workout.entry.0251"].tap()
        XCTAssertTrue(app.buttons["logging.logSet"].waitForExistence(timeout: 3))
        app.buttons["logging.logSet"].tap()
        app.dismissKeyboardIfPresent()
        app.buttons["logging.close"].tap()
        let count = app.staticTexts["workout.entry.0251.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 3))
        let logged = count.label
        XCTAssertTrue(logged.hasPrefix("1/"), logged)
        app.buttons["workout.close"].tap()

        let resume = app.buttons["log.empty.resumeWorkout"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["log.empty.startWorkout"].exists)
        resume.tap()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, logged)
    }

    func testLibraryNoResultsOffersCreateCustomExercise() {
        app.tabBars.buttons["Library"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Zzznotarealexercise")
        XCTAssertTrue(app.staticTexts["library.empty.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["library.empty.title"].label, "No exercises match 'Zzznotarealexercise'")
        app.buttons["library.empty.create"].tap()
        let name = app.textFields["custom.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Zzznotarealexercise")
    }
}
