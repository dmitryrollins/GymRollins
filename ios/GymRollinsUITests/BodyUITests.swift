import XCTest

final class BodyUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Selects all existing text (long-press → "Select All") before typing, since the weight
    /// field is trailing-aligned and a coordinate-based clear (tuned for center-aligned boxes
    /// elsewhere) can miss the cursor position and leave stray digits behind.
    private func replaceText(_ field: XCUIElement, with text: String, app: XCUIApplication) {
        field.tap()
        field.press(forDuration: 1.0)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 1) { selectAll.tap() }
        field.typeText(text)
    }

    func testEmptyStateThenAddWeighIn() {
        let app = XCUIApplication.launchReady([])
        app.tabBars.buttons["Body"].tap()

        XCTAssertTrue(app.staticTexts["body.empty"].waitForExistence(timeout: 5))

        app.buttons["body.addWeighIn"].tapCenter()
        let value = app.textFields["weighin.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        replaceText(value, with: "81.4", app: app)
        app.dismissKeyboardIfPresent()
        app.buttons["weighin.save"].tapCenter()

        XCTAssertTrue(app.staticTexts["body.empty"].waitForNonExistence(timeout: 5))
        let entry = app.descendants(matching: .any)["body.entry.0"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.label.contains("81.4 kg"), entry.label)
    }

    /// A goal date in the past means neither `weeklyChangeKg` (needs 2+ entries) nor
    /// `requiredWeeklyKg` (needs a future goal date) can be computed from a single weigh-in, so
    /// the trend line should read as "not enough data yet" rather than reusing the "no weigh-ins"
    /// empty-state text now that there IS a weigh-in.
    func testAddWeighInShowsTrendPendingWithoutEnoughDataForTrend() {
        let app = XCUIApplication.launchReady([], fixedNow: "2027-01-15T09:00:00Z")
        app.tabBars.buttons["Body"].tap()

        XCTAssertTrue(app.staticTexts["body.empty"].waitForExistence(timeout: 5))

        app.buttons["body.addWeighIn"].tapCenter()
        let value = app.textFields["weighin.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        replaceText(value, with: "81.4", app: app)
        app.dismissKeyboardIfPresent()
        app.buttons["weighin.save"].tapCenter()

        XCTAssertTrue(app.staticTexts["body.empty"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["body.trendPending"].waitForExistence(timeout: 5))
    }

    /// `ExerciseHistoryView` used to wrap its own `NavigationStack`, nesting one inside Body's
    /// existing stack when pushed from a strength row. Regression check: the push still lands on
    /// the history screen, and popping back (via its "Close" action, which also pops a pushed
    /// view) returns to Body.
    func testStrengthRowPushesExerciseHistoryWithinBodyStack() {
        let app = XCUIApplication.launchReady(["-seedHistory"])
        app.tabBars.buttons["Body"].tap()

        let liftRow = app.buttons["body.lift.0025"]
        XCTAssertTrue(liftRow.waitForExistence(timeout: 5))
        liftRow.tap()

        XCTAssertTrue(app.buttons["history.close"].waitForExistence(timeout: 5))
        app.buttons["history.close"].tap()

        // Back on Body, still scrolled down to the lift row: the (lazy) list only has the top card once scrolled up.
        XCTAssertTrue(liftRow.waitForExistence(timeout: 5))
        let addWeighIn = app.buttons["body.addWeighIn"]
        for _ in 0..<6 where !addWeighIn.exists { app.swipeDown() }
        XCTAssertTrue(addWeighIn.waitForExistence(timeout: 5))
    }

    func testInvalidWeighInRejected() {
        let app = XCUIApplication.launchReady([])
        app.tabBars.buttons["Body"].tap()

        XCTAssertTrue(app.buttons["body.addWeighIn"].waitForExistence(timeout: 5))
        app.buttons["body.addWeighIn"].tapCenter()
        let value = app.textFields["weighin.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        replaceText(value, with: "900", app: app)
        app.dismissKeyboardIfPresent()
        app.buttons["weighin.save"].tapCenter()

        XCTAssertTrue(app.staticTexts["Enter a weight between 30 and 300 kg"].waitForExistence(timeout: 5))
        XCTAssertTrue(value.exists)
    }
}
