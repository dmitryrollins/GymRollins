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
        XCTAssertTrue(app.staticTexts["library.title"].waitForExistence(timeout: 5))
    }

    /// Log, Library and Body have Today's header (owner, 2026-11-19): "R" for Settings and the screen's name in the
    /// pill, staying put while the screen scrolls under it.
    func testEveryTabHasTheHeader() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        for (tab, prefix) in [("Log", "log"), ("Library", "library"), ("Body", "body")] {
            // The tab bar minimizes as a screen scrolls down and comes back as it scrolls up.
            for _ in 0..<4 where !app.tabBars.buttons[tab].exists { app.swipeDown() }
            app.tabBars.buttons[tab].tap()
            let settings = app.buttons["\(prefix).settings"], title = app.staticTexts["\(prefix).title"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5), tab)
            XCTAssertEqual(title.label, tab)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "header-\(prefix)"
            shot.lifetime = .keepAlways
            add(shot)
            let frame = settings.frame
            app.swipeUp()
            XCTAssertEqual(settings.frame, frame, "\(tab)'s header scrolled away")
            settings.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), tab)
            app.navigationBars["Settings"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 5), "back on \(tab)")
        }
    }

    func testTodayShowsSaturdayPushDay() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["today.workout"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["today.workout"].label, "Push + Arms \u{00B7} 7 exercises")
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
