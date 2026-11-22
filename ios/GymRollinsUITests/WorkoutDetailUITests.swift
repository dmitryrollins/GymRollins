import XCTest

/// Plan 40: a GymRollins workout's detail in Apple Fitness' layout, on the in-memory Health store. `-fakeHealth` holds
/// the GymRollins watch app's copy of `-seedHistory`'s Sat 19 Sep workout (18:00–18:58:20 UTC): 412 of 489 kcal, a dozen
/// readings averaging 128 (the highest 162) and three after it, the last 124. Plan 39's Apple Watch strength recording
/// (18:02–18:55, 412 kcal, 128/162 BPM) attaches to the same workout; `-fakeHealthNoWatchCopy` leaves only it. The
/// older workout, Sat 12 Sep, has nothing in Health. `-fakeHealthEffortUnasked` turns Health on as build 4 did, without
/// the effort types, so the Effort card offers the Allow pill.
@MainActor
final class WorkoutDetailUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    // MARK: What it measured

    func testAWatchWorkoutShowsWhatFitnessShows() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-seedHistory"])
        enableHealth(app)
        openWorkout(app, 0)
        waitForValue(cell(app, "detail.workoutTime"), "58 minutes 20 seconds") // Health's read has landed
        let expected = [("detail.workoutTime", "Workout Time", "58 minutes 20 seconds"),
                        ("detail.activeKcal", "Active Calories", "412 kilocalories"),
                        ("detail.totalKcal", "Total Calories", "489 kilocalories"),
                        ("detail.avgHeartRate", "Avg. Heart Rate", "128 beats per minute"),
                        ("detail.maxHeartRate", "Max Heart Rate", "162 beats per minute")]
        for (identifier, label, value) in expected {
            let element = cell(app, identifier)
            XCTAssertEqual(element.label, label, identifier)
            XCTAssertEqual(element.value as? String, value, identifier)
        }
        XCTAssertEqual(app.staticTexts["detail.measuredBy"].label, "Measured by Apple Watch")
        XCTAssertEqual(app.staticTexts["detail.recordedBy"].label, "Apple Watch")
        XCTAssertFalse(cell(app, "detail.kcal").exists, "no estimate beside measured calories")
        XCTAssertFalse(app.staticTexts["detail.measured.title"].exists, "plan 39's block left this screen")
        XCTAssertTrue(app.buttons["detail.share"].exists)
        screenshot(app, "detail-measured")
        // Strength sits under Effort and the two charts: its lazy grid is built once scrolled near.
        let sets = cell(app, "detail.sets")
        scrollTo(sets, in: app)
        XCTAssertEqual(sets.value as? String, "3 sets")
        XCTAssertEqual(cell(app, "detail.exercises").value as? String, "1 exercise")
    }

    func testAnAttachedRecordingFillsTheGrid() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-fakeHealthNoWatchCopy", "-seedHistory"])
        enableHealth(app)
        openWorkout(app, 0)
        waitForValue(cell(app, "detail.workoutTime"), "53 minutes")
        XCTAssertEqual(cell(app, "detail.activeKcal").value as? String, "412 kilocalories")
        XCTAssertFalse(cell(app, "detail.totalKcal").exists, "the recording has no resting energy")
        XCTAssertEqual(cell(app, "detail.avgHeartRate").value as? String, "128 beats per minute")
        XCTAssertEqual(cell(app, "detail.maxHeartRate").value as? String, "162 beats per minute")
        XCTAssertEqual(app.staticTexts["detail.measuredBy"].label, "Measured by Apple Watch")
    }

    func testAWorkoutHealthMeasuredNothingForShowsTheEstimate() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-seedHistory"])
        enableHealth(app)
        openWorkout(app, 1) // Sat 12 Sep
        let kcal = cell(app, "detail.kcal")
        XCTAssertTrue(kcal.waitForExistence(timeout: 5))
        XCTAssertTrue(kcal.label.hasPrefix("Calories (estimated"), kcal.label)
        XCTAssertTrue((kcal.value as? String ?? "").hasPrefix("about "), "\(kcal.value ?? "")")
        XCTAssertEqual(cell(app, "detail.workoutTime").value as? String, "58 minutes 20 seconds", "the app's own")
        XCTAssertFalse(cell(app, "detail.activeKcal").exists)
        XCTAssertFalse(cell(app, "detail.totalKcal").exists)
        XCTAssertFalse(cell(app, "detail.avgHeartRate").exists)
        XCTAssertEqual(app.staticTexts["detail.measuredBy"].label, "Estimated from your sets and body weight")
        screenshot(app, "detail-estimate")
        app.buttons["detail.kcal.info"].tapCenter()
        XCTAssertTrue(app.buttons["calories.info.done"].waitForExistence(timeout: 5))
        app.buttons["calories.info.done"].tap()
        XCTAssertTrue(kcal.waitForExistence(timeout: 5))
    }

    func testWithHealthOffTheDetailShowsTheAppsValues() {
        let app = XCUIApplication.launchReady(["-seedHistory"])
        openWorkout(app, 0)
        XCTAssertTrue(cell(app, "detail.kcal").waitForExistence(timeout: 5))
        XCTAssertFalse(cell(app, "detail.avgHeartRate").exists)
        XCTAssertFalse(app.descendants(matching: .any)["detail.health"].exists)
        XCTAssertEqual(app.staticTexts["detail.recordedBy"].label, "iPhone")
    }

    // MARK: Effort

    func testRatingChangingAndClearingEffort() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-seedHistory"])
        enableHealth(app)
        openWorkout(app, 0)
        waitForValue(cell(app, "detail.workoutTime"), "58 minutes 20 seconds")
        let add = app.buttons["detail.addEffort"]
        scrollTo(add, in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["detail.effort.allow"].exists, "turning Health on asked for the effort types too")
        add.tap()
        XCTAssertTrue(app.buttons["effort.score.1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["effort.clear"].exists, "nothing to clear yet")
        rate(app, 6)
        let effort = app.buttons["detail.effort"]
        XCTAssertTrue(effort.waitForExistence(timeout: 5))
        waitForValue(effort, "6 out of 10, Moderate")
        XCTAssertEqual(effort.label, "Effort")
        XCTAssertFalse(cell(app, "detail.effort.healthError").exists, "Health took it: the watch's copy is there")
        screenshot(app, "detail-effort")
        effort.tap()
        XCTAssertTrue(app.buttons["effort.score.6"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["effort.score.6"].isSelected)
        rate(app, 8)
        waitForValue(effort, "8 out of 10, Hard")
        effort.tap()
        let clear = app.buttons["effort.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        growSheet(until: clear, in: app)
        clear.tapCenter()
        XCTAssertTrue(add.waitForExistence(timeout: 5), "back to Add Effort")
        XCTAssertFalse(effort.exists)
    }

    func testARatingHealthCantTakeStaysInTheAppAndSaysSo() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-seedHistory"])
        enableHealth(app)
        openWorkout(app, 1) // Sat 12 Sep: no GymRollins copy in Health to relate a rating to
        let add = app.buttons["detail.addEffort"]
        scrollTo(add, in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        rate(app, 4)
        waitForValue(app.buttons["detail.effort"], "4 out of 10, Moderate")
        let error = cell(app, "detail.effort.healthError")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Couldn't save to Apple Health")
    }

    func testWithHealthOffEffortIsRatedInTheApp() {
        let app = XCUIApplication.launchReady(["-seedHistory"])
        openWorkout(app, 0)
        let add = app.buttons["detail.addEffort"]
        scrollTo(add, in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["detail.effort.allow"].exists)
        add.tap()
        rate(app, 3)
        waitForValue(app.buttons["detail.effort"], "3 out of 10, Easy")
        XCTAssertFalse(cell(app, "detail.effort.healthError").exists, "Health is off: nothing to say")
    }

    /// A phone after the update: Health was turned on by build 4, before the effort types existed
    /// (`-fakeHealthEffortUnasked`), so the detail offers the glass Allow pill first. Its ask (the fake grants it) takes
    /// the pill away, and a rating then reaches Health.
    func testTheAllowPillAsksForTheEffortTypesThenARatingReachesHealth() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-fakeHealthEffortUnasked", "-seedHistory"])
        enableHealth(app)
        openWorkout(app, 0)
        waitForValue(cell(app, "detail.workoutTime"), "58 minutes 20 seconds")
        let allow = app.buttons["detail.effort.allow"]
        scrollTo(allow, in: app)
        XCTAssertTrue(allow.waitForExistence(timeout: 5), "Health on without the effort types: the Allow pill")
        screenshot(app, "detail-effort-allow")
        allow.tap()
        XCTAssertTrue(allow.waitForNonExistence(timeout: 5), "the ask ran and the fake granted it")
        let add = app.buttons["detail.addEffort"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        rate(app, 6)
        waitForValue(app.buttons["detail.effort"], "6 out of 10, Moderate")
        XCTAssertFalse(cell(app, "detail.effort.healthError").exists, "Health took it")
    }

    /// Picks `score` in the open Effort sheet and saves.
    private func rate(_ app: XCUIApplication, _ score: Int) {
        let chip = app.buttons["effort.score.\(score)"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: chip)], timeout: 5)
        let save = app.buttons["effort.save"]
        growSheet(until: save, in: app)
        save.tapCenter()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
    }

    /// The Effort sheet opens at its medium height; dragging its scale up grows it to large, so `element` (Save,
    /// Clear Rating) comes on screen.
    private func growSheet(until element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<2 where !element.isHittable { app.buttons["effort.score.1"].swipeUp() }
    }

    // MARK: Heart rate charts

    func testTheHeartRateChartsShowAndSpeakTheirSummary() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-seedHistory"])
        enableHealth(app)
        openWorkout(app, 0)
        let chart = cell(app, "detail.heartRateChart")
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        XCTAssertTrue(chart.label.hasPrefix("Heart rate ") && chart.label.hasSuffix(": average 128, maximum 162"),
                      chart.label)
        XCTAssertGreaterThanOrEqual(chart.frame.height, 140, "the chart's height is reserved")
        let post = cell(app, "detail.postHeartRateChart")
        scrollTo(post, in: app)
        XCTAssertTrue(post.label.hasPrefix("Heart rate after the workout, ")
                      && post.label.hasSuffix(": last reading 124"), post.label)
        screenshot(app, "detail-charts")
    }

    func testWithoutReadingsThereAreNoCharts() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-fakeHealthNoWatchCopy", "-seedHistory"])
        enableHealth(app)
        openWorkout(app, 0)
        waitForValue(cell(app, "detail.workoutTime"), "53 minutes")
        XCTAssertEqual(cell(app, "detail.avgHeartRate").value as? String, "128 beats per minute",
                       "the recording's own average, without readings")
        XCTAssertFalse(cell(app, "detail.heartRateChart").exists)
        XCTAssertFalse(cell(app, "detail.postHeartRateChart").exists)
    }

    // MARK: Accessibility text size

    /// AX-XL: one metric to a row, the Effort pill and the charts reachable, nothing clipped (the audit checks that).
    func testTheDetailReadsAtAnAccessibilityTextSize() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-seedHistory", "-UIPreferredContentSizeCategoryName",
                                               "UICTContentSizeCategoryAccessibilityXL"])
        enableHealth(app)
        openWorkout(app, 0)
        let time = cell(app, "detail.workoutTime")
        waitForValue(time, "58 minutes 20 seconds")
        let active = cell(app, "detail.activeKcal")
        XCTAssertLessThanOrEqual(time.frame.maxY, active.frame.minY + 1, "one metric to a row")
        screenshot(app, "detail-ax-xl")
        let add = app.buttons["detail.addEffort"]
        scrollTo(add, in: app)
        XCTAssertTrue(add.isHittable)
        let chart = cell(app, "detail.heartRateChart")
        scrollTo(chart, in: app)
        XCTAssertTrue(chart.exists)
        screenshot(app, "detail-ax-xl-charts")
    }

    /// AX-XL: the options sheet grows so Edit and Delete stay reachable, and edit mode's Cancel and Save each keep one
    /// line beside Back (capped at accessibility1, as Share is).
    func testEditingAtAnAccessibilityTextSize() {
        let app = XCUIApplication.launchReady(["-seedHistory", "-UIPreferredContentSizeCategoryName",
                                               "UICTContentSizeCategoryAccessibilityXL"])
        openWorkout(app, 0)
        app.buttons["detail.menu"].tap()
        let edit = app.buttons["detail.edit"]
        let delete = app.buttons["detail.delete"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(edit.isHittable && delete.isHittable, "both options on screen")
        XCTAssertLessThanOrEqual(delete.frame.maxY, window.maxY - 20, "Delete clear of the sheet's bottom edge")
        edit.tap()
        let cancel = app.buttons["detail.cancel"]
        let save = app.buttons["detail.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        let back = app.buttons["detail.back"]
        XCTAssertEqual(cancel.frame.height, save.frame.height, accuracy: 1, "Cancel on one line, as Save")
        XCTAssertLessThanOrEqual(cancel.frame.height, back.frame.height * 1.5, "beside the 44 pt Back circle")
        XCTAssertLessThanOrEqual(save.frame.maxX, window.maxX)
        XCTAssertGreaterThan(cancel.frame.minX, back.frame.maxX)
        screenshot(app, "detail-edit-ax-xl")
    }

    // MARK: Helpers

    /// Log › Settings › Apple Health, turned on there (it asks for every type and reads them), as in
    /// HealthActivityUITests.
    private func enableHealth(_ app: XCUIApplication) {
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tapCenter()
        let row = app.buttons["settings.health"]
        let tabBar = app.tabBars.firstMatch
        for _ in 0..<10 where !(row.exists && row.isHittable && (!tabBar.exists || row.frame.maxY < tabBar.frame.minY)) {
            app.swipeUp()
        }
        row.tapCenter()
        let toggle = app.switches["health.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let inner = toggle.switches.firstMatch
        if inner.exists { inner.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let status = app.descendants(matching: .any)["health.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Connected")
    }

    /// The Log's `index`th GymRollins workout (0: Sat 19 Sep, 1: Sat 12 Sep), opened.
    private func openWorkout(_ app: XCUIApplication, _ index: Int) {
        app.tabBars.buttons["Log"].tap()
        if !app.buttons["log.settings"].waitForExistence(timeout: 2) { app.tabBars.buttons["Log"].tap() }
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10))
        let card = cards.element(boundBy: index)
        scrollTo(card, in: app)
        card.tap()
        XCTAssertTrue(app.buttons["detail.menu"].waitForExistence(timeout: 5))
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    /// A metric cell: one element whose label is the metric's name and whose value speaks the unit in full.
    private func cell(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Waits for `element`'s value: Health's read redraws the screen after the app's own values.
    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 5) {
        let matches = NSPredicate(format: "value == %@", value)
        wait(for: [expectation(for: matches, evaluatedWith: element)], timeout: timeout)
    }

    /// Keeps a screenshot in the result for the owner's review.
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
