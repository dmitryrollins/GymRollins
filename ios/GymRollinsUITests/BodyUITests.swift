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

    /// Body opens on Muscles (the recovery card is on screen without scrolling), and the section picked is kept
    /// after leaving the tab and coming back.
    func testBodyOpensOnMusclesAndRemembersTheSectionPicked() {
        let app = XCUIApplication.launchReady([])
        app.tabBars.buttons["Body"].tap()

        let section = app.segmentedControls["body.section"]
        XCTAssertTrue(section.waitForExistence(timeout: 5))
        XCTAssertTrue(section.buttons["Muscles"].isSelected)
        let recovery = app.descendants(matching: .any)["body.recovery"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        XCTAssertTrue(recovery.isHittable, "Muscle Recovery should be on screen without scrolling")
        XCTAssertFalse(app.buttons["body.addWeighIn"].exists)

        app.openBodySection("Weight")
        XCTAssertTrue(app.buttons["body.addWeighIn"].waitForExistence(timeout: 5))
        XCTAssertFalse(recovery.exists)

        app.tabBars.buttons["Today"].tap()
        app.tabBars.buttons["Body"].tap()
        let weight = app.segmentedControls["body.section"].buttons["Weight"]
        XCTAssertTrue(weight.waitForExistence(timeout: 5))
        XCTAssertTrue(weight.isSelected)
        XCTAssertTrue(app.buttons["body.addWeighIn"].exists)
    }

    func testEmptyStateThenAddWeighIn() {
        let app = XCUIApplication.launchReady([])
        app.tabBars.buttons["Body"].tap()
        app.openBodySection("Weight")

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
        app.openBodySection("Weight")

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
        app.openBodySection("Strength")

        let liftRow = app.buttons["body.lift.0025"]
        XCTAssertTrue(liftRow.waitForExistence(timeout: 5))
        liftRow.tap()

        XCTAssertTrue(app.buttons["history.close"].waitForExistence(timeout: 5))
        app.buttons["history.close"].tap()

        // Back on Body, still on the Strength section.
        XCTAssertTrue(liftRow.waitForExistence(timeout: 5))
        app.openBodySection("Weight")
        XCTAssertTrue(app.buttons["body.addWeighIn"].waitForExistence(timeout: 5))
    }

    func testInvalidWeighInRejected() {
        let app = XCUIApplication.launchReady([])
        app.tabBars.buttons["Body"].tap()
        app.openBodySection("Weight")

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
