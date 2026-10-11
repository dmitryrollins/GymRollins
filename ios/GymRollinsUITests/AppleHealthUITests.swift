import XCTest

/// Plan 15: Apple Health on the in-memory fake store (`-fakeHealth`, seeded with three Withings weigh-ins) and the
/// calorie estimate on Summary / Log.
final class AppleHealthUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func openHealthSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tapCenter()
        let row = app.buttons["settings.health"]
        // The floating tab bar overlaps the bottom of the list, so "hittable" isn't enough on tall screens:
        // keep scrolling until the row sits fully above the tab bar.
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

    private func enableHealth(_ app: XCUIApplication) {
        openHealthSettings(app)
        let toggle = app.switches["health.toggle"]
        let inner = toggle.switches.firstMatch
        if inner.exists { inner.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let status = app.descendants(matching: .any)["health.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Connected")
    }

    func testEnablingInSettingsBringsHealthWeightsToBody() {
        let app = XCUIApplication.launchReady(["-fakeHealth"])
        enableHealth(app)
        XCTAssertTrue(app.descendants(matching: .any)["health.permission.workouts"].label.contains("Allowed"))

        app.tabBars.buttons["Body"].tap()
        let newest = app.descendants(matching: .any)["body.entry.0"]
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        XCTAssertTrue(newest.label.contains("81.6 kg"), newest.label)
        XCTAssertTrue(newest.label.contains("Apple Health"), newest.label)
        XCTAssertTrue(app.descendants(matching: .any)["body.entry.2"].label.contains("81 kg"))
    }

    func testFinishedWorkoutShowsCaloriesAndIsSavedToHealth() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-seedHistory", "-workoutStartedMinutesAgo", "45"])
        enableHealth(app)

        app.tabBars.buttons["Today"].tap()
        app.startWorkout()
        app.openExercise("0025")
        app.buttons["logging.logAll"].tapCenter()
        app.buttons["logging.next"].tapCenter()
        app.buttons["workout.finish"].tapCenter()
        XCTAssertTrue(app.buttons["finish.discardEmpty"].waitForExistence(timeout: 3))
        app.buttons["finish.discardEmpty"].tap()

        XCTAssertTrue(app.staticTexts["summary.title"].waitForExistence(timeout: 5))
        let kcal = app.descendants(matching: .any)["summary.kcal"]
        XCTAssertTrue(kcal.waitForExistence(timeout: 5))
        XCTAssertTrue(kcal.label.contains("kcal") && kcal.label.contains("estimated"), kcal.label)
        let health = app.descendants(matching: .any)["summary.health"]
        XCTAssertTrue(health.waitForExistence(timeout: 5))
        let saved = NSPredicate(format: "label == %@", "Saved to Apple Health")
        wait(for: [expectation(for: saved, evaluatedWith: health)], timeout: 10)

        app.buttons["summary.kcal.info"].tapCenter()
        XCTAssertTrue(app.buttons["calories.info.done"].waitForExistence(timeout: 5))
        let citation = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Herrmann SD'")).firstMatch
        XCTAssertTrue(citation.waitForExistence(timeout: 3))
        app.buttons["calories.info.done"].tap()

        app.buttons["summary.done"].tapCenter()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))
        // Log still shows Settings → Apple Health from earlier: tapping the selected tab again pops to its root.
        app.tabBars.buttons["Log"].tap()
        if !app.buttons["log.settings"].waitForExistence(timeout: 2) { app.tabBars.buttons["Log"].tap() }
        let week = app.staticTexts["log.week.kcal"]
        XCTAssertTrue(week.waitForExistence(timeout: 5))
        XCTAssertTrue(week.label.contains("kcal this week (estimated)"), week.label)
    }

    func testCaloriesShowWithoutHealthAndHealthLineStaysHidden() {
        let app = XCUIApplication.launchReady(["-seedHistory"])
        app.tabBars.buttons["Log"].tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.kcal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["detail.health"].exists)
    }
}
