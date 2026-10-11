import XCTest

/// Settings → Import CSV with the Strong / Hevy sample exports (`-importFixture <source>` skips the Files picker).
/// Launched with `-emptyStore` so the Log shows exactly the imported workouts.
@MainActor
final class ImportUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(fixture: String) -> XCUIApplication {
        XCUIApplication.launchReady(["-skipOnboarding", "-emptyStore", "-importFixture", fixture])
    }

    private func openImportFromSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.importCSV"]
        var swipes = 0
        while !(row.exists && row.isHittable) && swipes < 15 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["import.choose"].waitForExistence(timeout: 5))
    }

    /// Runs the import from the result screen: every unmatched name becomes a custom exercise.
    private func resolveAllAsCustomAndImport(_ app: XCUIApplication, expectedUnmatched: Int) {
        for index in 0..<expectedUnmatched {
            let row = app.buttons["result.match.\(index)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "missing unmatched row \(index)")
            row.tap()
            XCTAssertTrue(app.buttons["result.sheet.custom"].waitForExistence(timeout: 3))
            app.buttons["result.sheet.custom"].tap()
            XCTAssertTrue(app.buttons["result.sheet.custom"].waitForNonExistence(timeout: 3))
        }
        XCTAssertFalse(app.buttons["result.match.\(expectedUnmatched)"].exists, "more unmatched names than expected")
        app.buttons["result.continue"].tapCenter()
        XCTAssertTrue(app.descendants(matching: .any)["result.success"].waitForExistence(timeout: 10))
        app.buttons["result.continue"].tapCenter() // back to Settings
    }

    private func assertLogShows(_ app: XCUIApplication, workouts count: Int, named name: String) {
        app.tabBars.buttons["Log"].tap()
        let back = app.navigationBars.buttons.firstMatch
        if !app.buttons["log.settings"].waitForExistence(timeout: 2), back.exists { back.tap() }
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(cards.count, count)
        let titled = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(titled.waitForExistence(timeout: 5), "no workout named \(name)")
    }

    func testImportStrongExportThroughSettings() {
        let app = launch(fixture: "strong")
        openImportFromSettings(app)

        app.buttons["import.source.strong"].tap()
        XCTAssertTrue(app.buttons["import.source.strong"].isSelected)
        XCTAssertTrue(app.staticTexts["import.source.help"].label.contains("Export Strong Data"))

        app.buttons["import.choose"].tap()
        // Strong's current export has no unit column, so the screen asks (default: the profile's lb).
        let pounds = app.buttons["import.unit.lb"]
        let kilograms = app.buttons["import.unit.kg"]
        XCTAssertTrue(pounds.waitForExistence(timeout: 5))
        XCTAssertTrue(pounds.isSelected)
        // A pick that differs from the profile survives a trip to the preview and back (it used to reset).
        kilograms.tap()
        XCTAssertTrue(app.buttons["import.run"].waitForExistence(timeout: 5))
        app.buttons["import.run"].tapCenter()
        XCTAssertTrue(app.buttons["onboarding.back"].waitForExistence(timeout: 5))
        app.buttons["onboarding.back"].tap()
        XCTAssertTrue(kilograms.waitForExistence(timeout: 5))
        XCTAssertTrue(kilograms.isSelected)
        // The sample is in pounds.
        pounds.tap()
        XCTAssertTrue(app.staticTexts["import.file"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["import.file"].label.contains("Strong"), app.staticTexts["import.file"].label)

        app.buttons["import.run"].tapCenter()
        let skipped = app.staticTexts["result.skipped"]
        XCTAssertTrue(skipped.waitForExistence(timeout: 5))
        XCTAssertEqual(skipped.label, "1 row skipped")
        XCTAssertEqual(app.staticTexts["result.warmups"].label, "2 warm-up sets kept")
        resolveAllAsCustomAndImport(app, expectedUnmatched: 1)

        assertLogShows(app, workouts: 3, named: "Push, heavy")
    }

    func testImportHevyExportWithAutoDetect() {
        let app = launch(fixture: "hevy")
        openImportFromSettings(app)

        XCTAssertTrue(app.buttons["import.source.auto"].isSelected)
        app.buttons["import.choose"].tap()
        XCTAssertTrue(app.staticTexts["import.file"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["import.file"].label.contains("Hevy"), app.staticTexts["import.file"].label)
        XCTAssertFalse(app.buttons["import.unit.kg"].exists) // the kg columns say so

        app.buttons["import.run"].tapCenter()
        XCTAssertTrue(app.staticTexts["result.skipped"].waitForExistence(timeout: 5))
        resolveAllAsCustomAndImport(app, expectedUnmatched: 1)

        assertLogShows(app, workouts: 3, named: "Upper, A")
    }

    func testPickingTheWrongAppExplainsAndAutoDetectRecovers() {
        let app = launch(fixture: "hevy")
        openImportFromSettings(app)

        app.buttons["import.source.fitNotes"].tap()
        app.buttons["import.choose"].tap()
        let error = app.staticTexts["import.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "This looks like a Hevy export, not FitNotes. Pick Hevy or Auto-detect.")

        app.buttons["import.source.auto"].tap()
        XCTAssertTrue(error.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["import.file"].label.contains("Hevy"))
    }
}
