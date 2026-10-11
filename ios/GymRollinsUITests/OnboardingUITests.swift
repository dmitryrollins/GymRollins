import XCTest

final class OnboardingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-onboarding", "-fixedNow", "2026-09-26T09:00:00Z"] + extra
        app.launch()
        return app
    }

    /// Fills the required bodyweight field and taps Continue (height/training days/experience keep the
    /// owner's seeded defaults).
    private func completeProfileSetup(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["setup.continue"].waitForExistence(timeout: 5))
        let bodyweight = app.textFields["setup.bodyweight"]
        XCTAssertTrue(bodyweight.waitForExistence(timeout: 5))
        bodyweight.tap()
        bodyweight.typeText("180")
        app.dismissKeyboardIfPresent()
        app.buttons["setup.continue"].tap()
    }

    func testFullOnboardingWithImport() {
        let app = launch(extra: ["-importFixture"])

        XCTAssertTrue(app.buttons["onboarding.skip"].waitForExistence(timeout: 5))
        app.buttons["onboarding.skip"].tap()

        completeProfileSetup(app)

        // Import CSV: the fixture bypasses the system file picker.
        XCTAssertTrue(app.buttons["import.choose"].waitForExistence(timeout: 5))
        app.buttons["import.choose"].tap()
        XCTAssertTrue(app.buttons["import.run"].waitForExistence(timeout: 5))
        app.buttons["import.run"].tap()

        // The fixture's bad row (line 17) is reported, not silently dropped.
        let skipped = app.staticTexts["result.skipped"]
        XCTAssertTrue(skipped.waitForExistence(timeout: 5))
        XCTAssertEqual(skipped.label, "1 row skipped")
        app.buttons["result.skipped.toggle"].tap()
        let skippedRow = app.staticTexts["result.skipped.row.0"]
        XCTAssertTrue(skippedRow.waitForExistence(timeout: 3))
        XCTAssertTrue(skippedRow.label.hasPrefix("Line 17: "), skippedRow.label)
        app.buttons["result.skipped.toggle"].tap()
        XCTAssertTrue(skippedRow.waitForNonExistence(timeout: 3))

        // Import Result: resolve both unmatched names ("Dumbbell Biceps Curls", "Zorblax Press") as custom.
        XCTAssertTrue(app.buttons["result.match.0"].waitForExistence(timeout: 5))
        app.buttons["result.match.0"].tap()
        XCTAssertTrue(app.buttons["result.sheet.custom"].waitForExistence(timeout: 3))
        app.buttons["result.sheet.custom"].tap()
        XCTAssertTrue(app.buttons["result.sheet.custom"].waitForNonExistence(timeout: 3))

        XCTAssertTrue(app.buttons["result.match.1"].waitForExistence(timeout: 5))
        app.buttons["result.match.1"].tap()
        XCTAssertTrue(app.buttons["result.sheet.custom"].waitForExistence(timeout: 3))
        app.buttons["result.sheet.custom"].tap()
        XCTAssertTrue(app.buttons["result.sheet.custom"].waitForNonExistence(timeout: 3))

        // Runs the import; on success the header flips to "Import complete" and the button becomes "Continue".
        app.buttons["result.continue"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["result.success"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["result.skipped"].label, "1 row skipped") // still on the summary
        app.buttons["result.continue"].tap() // proceeds to Connect Claude

        XCTAssertTrue(app.buttons["onboarding.done"].waitForExistence(timeout: 5))
        app.buttons["onboarding.done"].tap()

        // Today shows (onboarding finished).
        XCTAssertTrue(app.staticTexts["today.summary"].waitForExistence(timeout: 5))

        // Log shows the 3 imported workouts.
        app.tabBars.buttons["Log"].tap()
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(cards.count, 3)
    }

    func testSkipImportFinishesWithNoWorkouts() {
        let app = launch()

        XCTAssertTrue(app.buttons["onboarding.skip"].waitForExistence(timeout: 5))
        app.buttons["onboarding.skip"].tap()

        completeProfileSetup(app)

        XCTAssertTrue(app.buttons["import.skip"].waitForExistence(timeout: 5))
        app.buttons["import.skip"].tap() // "Start fresh": no Import Result step

        XCTAssertTrue(app.buttons["onboarding.later"].waitForExistence(timeout: 5))
        app.buttons["onboarding.later"].tap()

        XCTAssertTrue(app.staticTexts["today.summary"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Log"].tap()
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertFalse(cards.firstMatch.waitForExistence(timeout: 3))
    }

    func testProfileSetupShowsValidationErrorForMissingBodyweight() {
        let app = launch()

        XCTAssertTrue(app.buttons["onboarding.skip"].waitForExistence(timeout: 5))
        app.buttons["onboarding.skip"].tap()

        XCTAssertTrue(app.buttons["setup.continue"].waitForExistence(timeout: 5))
        app.buttons["setup.continue"].tap() // bodyweight left empty

        XCTAssertTrue(app.staticTexts["setup.error"].waitForExistence(timeout: 5))
        // Still on Profile Setup: didn't advance to the Import step.
        XCTAssertFalse(app.buttons["import.choose"].exists)
        XCTAssertTrue(app.buttons["setup.continue"].exists)
    }
}
