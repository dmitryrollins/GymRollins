import XCTest

/// Plan 39: Apple Health activities on the in-memory fake store. `-fakeHealth` also seeds:
/// - yesterday's Apple Watch walk (Fri 25 Sep, 07:00 UTC, 45 min, 180 kcal);
/// - an Indoor Cycle from a LifeFitness bike (Thu 24 Sep, 16:02 UTC, 5 min 8 s, 2.26 km, 40 of 48 kcal, 138 W, 62 rpm):
///   under 10 minutes, so it doesn't count toward the streak;
/// - an Apple Watch strength recording during `-seedHistory`'s workout of Sat 19 Sep;
/// - seven days of steps, today's being 4,210.
///
/// `-healthBeforeActivity` starts with Health on, as a build from before plan 39 left it.
@MainActor
final class HealthActivityUITests: XCTestCase {
    private let walk = "00000000-0000-4000-8000-00000000A001"
    private let strength = "00000000-0000-4000-8000-00000000A002"
    private let ride = "00000000-0000-4000-8000-00000000A003"

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

    /// A metric cell: one element whose label is the metric's name and whose value speaks the unit in full.
    private func cell(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Keeps a screenshot in the result for the owner's review.
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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

    /// Review M2: with Health off, what was read still shows, so the two switches stay to hide it.
    func testWithHealthOffTheSwitchesStillHideWhatWasRead() {
        let app = XCUIApplication.launchReady(["-fakeHealth"])
        enableHealth(app)
        flip(app.switches["health.toggle"], in: app)
        let workouts = app.switches["health.read.workouts"]
        scrollTo(workouts, in: app)
        XCTAssertTrue(workouts.waitForExistence(timeout: 3), "the switch stays with Health off")
        XCTAssertTrue(app.switches["health.read.days"].exists)
        openLog(app)
        let card = app.buttons["log.outside.\(walk)"]
        scrollTo(card, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 5), "what was read stays visible")
        openHealthSettings(app)
        flip(app.switches["health.read.workouts"], in: app)
        openLog(app)
        XCTAssertFalse(app.buttons["log.outside.\(walk)"].waitForExistence(timeout: 3))
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
        XCTAssertEqual(row.label, "Activity")
        let summary = row.value as? String ?? ""
        XCTAssertTrue(summary.hasPrefix("Steps 4,210, Move 210 kilocalories, Exercise 18 minutes"), summary)
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

    // MARK: Log

    func testAWalkShowsInTheLogAndOpensItsDetail() {
        let app = XCUIApplication.launchReady(["-fakeHealth"])
        enableHealth(app)
        openLog(app)
        let other = app.staticTexts["log.week.otherKcal"]
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        XCTAssertEqual(other.label, "+ 220 kcal from other activities (measured)", "the walk's 180 and the ride's 40")
        let card = app.buttons["log.outside.\(walk)"]
        scrollTo(card, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.label.contains("Walk") && card.label.contains("Apple Watch"), card.label)
        screenshot(app, "log-outside-walk")
        card.tap()
        let title = app.staticTexts["outside.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Walk")
        XCTAssertEqual(cell(app, "outside.avgHr").label, "Avg. Heart Rate")
        XCTAssertEqual(cell(app, "outside.avgHr").value as? String, "102 beats per minute")
        XCTAssertEqual(cell(app, "outside.distance").value as? String, "2.11 miles", "the owner's profile is in lb")
        XCTAssertFalse(cell(app, "outside.power").exists, "a walk has no power")
        XCTAssertEqual(app.staticTexts["outside.healthNote"].label, "Change or delete it in the Health app.")
        screenshot(app, "outside-walk-detail")
        app.buttons["outside.back"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    func testARideShowsPowerCadenceAndTotalCalories() {
        let app = XCUIApplication.launchReady(["-fakeHealth"])
        enableHealth(app)
        openLog(app)
        let card = app.buttons["log.outside.\(ride)"]
        scrollTo(card, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.label.hasPrefix("Cycling, 1.40 miles, ") && card.label.hasSuffix("5 min, LifeFitness"),
                      card.label)
        card.tap()
        XCTAssertTrue(app.staticTexts["outside.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["outside.title"].label, "Cycling")
        let expected = [("outside.duration", "Workout Time", "5 minutes 8 seconds"),
                        ("outside.distance", "Distance", "1.40 miles"),
                        ("outside.kcal", "Active Calories", "40 kilocalories"),
                        ("outside.totalKcal", "Total Calories", "48 kilocalories"),
                        ("outside.power", "Avg. Power", "138 watts"),
                        ("outside.cadence", "Avg. Cadence", "62 revolutions per minute"),
                        ("outside.avgHr", "Avg. Heart Rate", "128 beats per minute"),
                        ("outside.maxHr", "Max Heart Rate", "151 beats per minute")]
        for (identifier, label, value) in expected {
            let element = cell(app, identifier)
            scrollTo(element, in: app)
            XCTAssertEqual(element.label, label, identifier)
            XCTAssertEqual(element.value as? String, value, identifier)
        }
    }

    func testTurningWorkoutsFromOtherAppsOffHidesThem() {
        let app = XCUIApplication.launchReady(["-fakeHealth"])
        enableHealth(app)
        flip(app.switches["health.read.workouts"], in: app)
        openLog(app)
        XCTAssertFalse(app.buttons["log.outside.\(walk)"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["log.week.otherKcal"].exists)
    }

    // MARK: Workout detail

    func testAnAppleWatchRecordingDuringAWorkoutShowsOnItAndNotOnItsOwn() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-seedHistory"])
        enableHealth(app)
        openLog(app)
        let workouts = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(workouts.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["log.outside.\(strength)"].exists, "attached: not listed on its own")
        workouts.firstMatch.tap() // Sat 19 Sep, the newest seeded workout
        let measured = app.staticTexts["detail.measured.title"]
        XCTAssertTrue(measured.waitForExistence(timeout: 5))
        XCTAssertEqual(measured.label, "Apple Watch measured")
        XCTAssertEqual(cell(app, "detail.measured.kcal").value as? String, "412 kilocalories")
        XCTAssertEqual(cell(app, "detail.measured.avgHr").value as? String, "128 beats per minute")
        XCTAssertEqual(cell(app, "detail.measured.maxHr").value as? String, "162 beats per minute")
        XCTAssertFalse(cell(app, "detail.measured.power").exists)
        screenshot(app, "workout-measured")
    }
}
