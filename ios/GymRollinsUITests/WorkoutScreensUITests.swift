import XCTest

final class WorkoutScreensUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testLoggingBasics() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }

        app.startWorkout()
        XCTAssertTrue(app.buttons["workout.entry.0025"].waitForExistence(timeout: 5))
        app.buttons["workout.entry.0025"].tap()

        XCTAssertTrue(app.staticTexts["logging.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["logging.title"].label, "Barbell Bench Press")
        XCTAssertEqual(app.textFields["logging.set.0.weight"].value as? String, "45")

        app.buttons["logging.logSet"].tapCenter()
        XCTAssertTrue(app.buttons["logging.rest.skip"].waitForExistence(timeout: 3))
        app.buttons["logging.rest.skip"].tap()

        app.buttons["logging.chip.plates"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["plates.side.45"].waitForExistence(timeout: 3))
    }

    /// Swapping keeps the entry id but changes the exercise: the "Last time" hint must follow the
    /// replacement (which has no history here), not keep showing the bench press numbers.
    func testSwapReloadsProgressionHint() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.startWorkout()
        XCTAssertTrue(app.buttons["workout.entry.0025"].waitForExistence(timeout: 5))
        app.buttons["workout.entry.0025"].tap()
        XCTAssertTrue(app.staticTexts["logging.hint"].waitForExistence(timeout: 5))

        app.tapLoggingChip("logging.chip.swap")
        let firstCandidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'swap.row.'")).firstMatch
        XCTAssertTrue(firstCandidate.waitForExistence(timeout: 3))
        firstCandidate.tap()
        XCTAssertTrue(app.staticTexts["logging.title"].waitForExistence(timeout: 3))
        XCTAssertNotEqual(app.staticTexts["logging.title"].label, "Barbell Bench Press")
        XCTAssertTrue(app.staticTexts["logging.hint"].waitForNonExistence(timeout: 3))
    }

    /// `ExerciseHistoryView` no longer wraps its own `NavigationStack` (that nested one inside
    /// Body's when pushed from a strength row), so the History chip's sheet now supplies its own
    /// `NavigationStack` at the presentation site. Regression check: the sheet still opens and
    /// its "Close" button still dismisses it back to logging.
    func testHistoryChipShowsExerciseHistorySheet() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.startWorkout()
        XCTAssertTrue(app.buttons["workout.entry.0025"].waitForExistence(timeout: 5))
        app.buttons["workout.entry.0025"].tap()

        XCTAssertTrue(app.buttons["logging.chip.history"].waitForExistence(timeout: 5))
        app.buttons["logging.chip.history"].tap()

        XCTAssertTrue(app.buttons["history.close"].waitForExistence(timeout: 5))
        app.buttons["history.close"].tap()

        XCTAssertTrue(app.staticTexts["logging.title"].waitForExistence(timeout: 5))
    }
}
