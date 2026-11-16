import XCTest

/// Plan 39: Apple Health activities on the in-memory fake store. `-fakeHealth` also seeds:
/// - yesterday's Apple Watch walk (Fri 25 Sep, 07:00 UTC, 45 min, 180 kcal);
/// - an Apple Watch strength recording during `-seedHistory`'s workout of Sat 19 Sep;
/// - seven days of steps, today's being 4,210.
///
/// `-healthBeforeActivity` starts with Health on, as a build from before plan 39 left it.
@MainActor
final class HealthActivityUITests: XCTestCase {
    private let walk = "00000000-0000-4000-8000-00000000A001"
    private let strength = "00000000-0000-4000-8000-00000000A002"

    override func setUp() { continueAfterFailure = false }

    /// Log › Settings › Apple Health, scrolled clear of the floating tab bar (as in AppleHealthUITests).
    private func openHealthSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tapCenter()
        let row = app.buttons["settings.health"]
        let tabBar = app.tabBars.firstMatch
        func clearOfTabBar() -> Bool {
            row.exists && row.isHittable && (!tabBar.exists || row.frame.maxY < tabBar.frame.minY)
        }
        var swipes = 0
        while !clearOfTabBar() && swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        row.tapCenter()
        XCTAssertTrue(app.switches["health.toggle"].waitForExistence(timeout: 5))
    }

    /// Turns Health on there, which asks for every type, the activity ones included, and reads them.
    private func enableHealth(_ app: XCUIApplication) {
        openHealthSettings(app)
        let toggle = app.switches["health.toggle"]
        let inner = toggle.switches.firstMatch
        if inner.exists { inner.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let status = app.descendants(matching: .any)["health.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Connected")
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    /// Flips a SwiftUI `Toggle` and waits for its value to change (as in AgentsUITests).
    private func flip(_ toggle: XCUIElement, in app: XCUIApplication) {
        scrollTo(toggle, in: app)
        let before = toggle.value as? String
        let inner = toggle.switches.firstMatch
        if inner.exists { inner.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let changed = NSPredicate(format: "value != %@", before ?? "")
        wait(for: [expectation(for: changed, evaluatedWith: toggle)], timeout: 3)
    }

    /// The Log tab's root (it may still show Settings).
    private func openLog(_ app: XCUIApplication) {
        app.tabBars.buttons["Log"].tap()
        if !app.buttons["log.settings"].waitForExistence(timeout: 2) { app.tabBars.buttons["Log"].tap() }
        XCTAssertTrue(app.buttons["log.settings"].waitForExistence(timeout: 5))
    }

    // MARK: Settings

    func testSettingsReadsFromHealthWithTwoSwitches() {
        let app = XCUIApplication.launchReady(["-fakeHealth"])
        enableHealth(app)
        let workouts = app.switches["health.read.workouts"]
        scrollTo(workouts, in: app)
        XCTAssertEqual(workouts.value as? String, "1")
        XCTAssertEqual(app.switches["health.read.days"].value as? String, "1")
        XCTAssertFalse(app.buttons["health.activity.allow"].exists, "turning Health on asked for every type")
        flip(workouts, in: app)
        XCTAssertEqual(workouts.value as? String, "0")
    }

    func testSettingsAsksForActivityWhenHealthWasOnBefore() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-healthBeforeActivity"])
        openHealthSettings(app)
        let allow = app.buttons["health.activity.allow"]
        scrollTo(allow, in: app)
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        allow.tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: allow)], timeout: 10)
    }

    // MARK: Today

    func testTodayShowsTodaysStepsAndTheLastSevenDays() {
        let app = XCUIApplication.launchReady(["-fakeHealth"])
        enableHealth(app)
        app.tabBars.buttons["Today"].tap()
        let row = app.buttons["today.activity"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        scrollTo(row, in: app)
        XCTAssertTrue(row.label.contains("4,210 steps"), row.label)
        row.tap()
        let days = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'activity.day.'"))
        XCTAssertTrue(days.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(days.count, 7)
        app.buttons["activity.week.done"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    func testTheOneTimeCardAsksThenGoes() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-healthBeforeActivity"])
        let allow = app.buttons["today.activityCard.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["today.activity"].exists, "nothing is read before the ask")
        scrollTo(allow, in: app)
        allow.tap()
        XCTAssertTrue(app.buttons["today.activity"].waitForExistence(timeout: 10))
        XCTAssertFalse(allow.exists)
    }

    func testNotNowHidesTheCardForGood() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-healthBeforeActivity"])
        let notNow = app.buttons["today.activityCard.notNow"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 10))
        scrollTo(notNow, in: app)
        notNow.tap()
        XCTAssertFalse(app.buttons["today.activityCard.allow"].waitForExistence(timeout: 2))
        app.tabBars.buttons["Log"].tap()
        app.tabBars.buttons["Today"].tap()
        XCTAssertFalse(app.buttons["today.activityCard.allow"].waitForExistence(timeout: 2))
    }

    func testTurningStepsOffHidesTheRow() {
        let app = XCUIApplication.launchReady(["-fakeHealth"])
        enableHealth(app)
        flip(app.switches["health.read.days"], in: app)
        app.tabBars.buttons["Today"].tap()
        XCTAssertFalse(app.buttons["today.activity"].waitForExistence(timeout: 3))
    }
}
