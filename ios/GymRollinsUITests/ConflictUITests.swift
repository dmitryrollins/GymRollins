import XCTest

/// Conflict review against the DEBUG `-seedConflict` fake server (hermetic: no network, no auth). The fake
/// reports the first pushed workout as edited on another device (one set fewer).
@MainActor
final class ConflictUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launchWithConflict() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-seedHistory", "-seedConflict"]
        app.launch()
        return app
    }

    private func openReview(_ app: XCUIApplication) {
        let banner = app.buttons["sync.banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertTrue(banner.label.contains("1 workout changed on another device"), banner.label)
        banner.tap()
        XCTAssertTrue(app.buttons["conflict.keepLocal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["conflict.remote.sets"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["conflict.local.sets"].label, "3 sets")
        XCTAssertEqual(app.staticTexts["conflict.remote.sets"].label, "2 sets")
    }

    func testKeepThisIPhonesVersionClearsTheConflict() {
        let app = launchWithConflict()
        openReview(app)
        app.buttons["conflict.keepLocal"].tap()
        XCTAssertTrue(app.buttons["conflict.keepLocal"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sync.banner"].waitForNonExistence(timeout: 5))
    }

    func testKeepOtherReplacesTheLocalWorkout() {
        let app = launchWithConflict()
        app.tabBars.buttons["Log"].tap()
        openReview(app)
        app.buttons["conflict.keepRemote"].tap()
        XCTAssertTrue(app.buttons["sync.banner"].waitForNonExistence(timeout: 5))
        // The seeded history holds two 3-set bench workouts; the other device's version has 2 sets.
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(cards.count, 2)
    }
}
