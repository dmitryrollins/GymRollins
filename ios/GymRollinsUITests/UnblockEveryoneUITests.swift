import XCTest

/// "Unblock everyone" in Settings, against the fake catalogue (two people blocked to start).
final class UnblockEveryoneUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func openSettings(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication.launchReady(["-fakeGymCatalog"] + extra) { $0.tabBars.firstMatch }
        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.buttons["log.settings"].waitForExistence(timeout: 5))
        app.buttons["log.settings"].tap()
        return app
    }

    /// A `Form` only materializes rows near the viewport: swipe first, then wait.
    private func scrollToHittable(_ app: XCUIApplication, _ element: XCUIElement) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < 15 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
    }

    func testUnblockEveryoneAsksFirstThenSaysHowManyWereCleared() {
        let app = openSettings(["-fakeSignedIn"])
        let row = app.buttons["settings.unblockAll"]
        scrollToHittable(app, row)
        row.tap()
        let confirm = app.buttons["settings.unblockAll.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isHittable, "the dialog can't open under the tab bar")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), "tapping away closes the dialog")
        XCTAssertFalse(app.staticTexts["settings.unblockAll.result"].exists, "and clears nothing")

        row.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let result = app.staticTexts["settings.unblockAll.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertEqual(result.label, "Unblocked 2 people.")

        scrollToHittable(app, row)
        row.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["No one was blocked."].waitForExistence(timeout: 5), "a second time finds none")
    }

    func testSignedOutHasNoUnblockRow() {
        let app = openSettings([])
        XCTAssertTrue(app.buttons["settings.claude"].waitForExistence(timeout: 10))
        let erase = app.buttons["settings.delete"]
        scrollToHittable(app, erase)
        XCTAssertFalse(app.buttons["settings.unblockAll"].exists)
    }
}
