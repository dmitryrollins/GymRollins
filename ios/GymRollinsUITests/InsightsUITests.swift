import XCTest

/// Recovery map, weekly set targets and streaks on the `-seedInsights` history (five goal-met weeks, then this
/// week's Mon/Wed/Fri sessions; the owner's 4-day goal). Screenshots are attached as "insights-*".
final class InsightsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        XCUIApplication.launchReady(["-seedInsights"] + extra) { $0.buttons["today.start"] }
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "insights-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Scrolls `scroller` up until `target` exists and is hittable (lazy List/Form rows).
    private func scroll(_ scroller: XCUIElement, to target: XCUIElement, attempts: Int = 8) {
        for _ in 0..<attempts where !(target.exists && target.isHittable) { scroller.swipeUp() }
        XCTAssertTrue(target.waitForExistence(timeout: 3), "never scrolled to \(target)")
    }

    func testTodayRecoveryCardOpensMapAndMuscleSheet() {
        let app = launch()
        let card = element(app, "today.recovery")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.label.localizedCaseInsensitiveContains("Muscle recovery"), card.label)
        XCTAssertTrue(card.label.contains("Fresh: "), card.label)
        XCTAssertTrue(card.label.contains("Legs limited"), card.label) // owner's knee note
        screenshot(app, "today-card")

        card.tap()
        XCTAssertTrue(element(app, "recovery.summary").waitForExistence(timeout: 5))
        let shoulders = app.buttons["recovery.region.front.shoulders"]
        XCTAssertTrue(shoulders.waitForExistence(timeout: 3))
        XCTAssertTrue(shoulders.label.hasPrefix("Shoulders, "), shoulders.label)
        XCTAssertTrue(shoulders.label.hasSuffix("% recovered"), shoulders.label)
        let quads = app.buttons["recovery.region.front.quads"]
        XCTAssertTrue(quads.label.hasSuffix("limited by your injury note"), quads.label)
        screenshot(app, "map-front")

        shoulders.tap()
        let header = element(app, "muscle.header")
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertTrue(header.label.contains("% recovered"), header.label)
        XCTAssertTrue(element(app, "muscle.lastTrained").label.hasPrefix("Last trained "))
        XCTAssertTrue(element(app, "muscle.session").waitForExistence(timeout: 3))
        screenshot(app, "muscle-sheet")
        app.buttons["muscle.done"].tap()
        XCTAssertTrue(app.buttons["muscle.done"].waitForNonExistence(timeout: 3))

        app.segmentedControls["recovery.side"].buttons["Back"].tap()
        let lats = app.buttons["recovery.region.back.lats"]
        XCTAssertTrue(lats.waitForExistence(timeout: 3))
        XCTAssertTrue(lats.label.hasPrefix("Lats, "), lats.label)
        screenshot(app, "map-back")
    }

    func testBodyTabShowsRecoveryAndWeeklySets() {
        let app = launch()
        app.tabBars.buttons["Body"].tap()
        let list = app.collectionViews.firstMatch
        let recovery = element(app, "body.recovery")
        scroll(list, to: recovery)
        let chest = element(app, "body.weeklySets.chest")
        scroll(list, to: chest)
        XCTAssertTrue(chest.label.hasPrefix("Chest, "), chest.label)
        XCTAssertTrue(chest.label.contains("of 10 to 20 sets this week"), chest.label)
        XCTAssertTrue(element(app, "body.weeklySets.lats").exists)
        screenshot(app, "body-weekly-sets")
    }

    func testWeeklyTargetEditPersistsAcrossRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-fixedNow", XCUIApplication.fixedNow, "-diskStore", "-resetStore",
                               "-seedInsights"]
        app.launchReady()
        openTargets(app)
        let value = element(app, "targets.value.chest")
        XCTAssertEqual(value.label, "10\u{2013}20 sets")
        let minStepper = app.steppers["targets.min.chest"]
        minStepper.buttons.element(boundBy: 1).tap() // [Decrement, Increment]
        minStepper.buttons.element(boundBy: 1).tap()
        XCTAssertEqual(value.label, "12\u{2013}20 sets")
        screenshot(app, "settings-targets")

        app.launchArguments = ["-uiTesting", "-fixedNow", XCUIApplication.fixedNow, "-diskStore"]
        app.launchReady()
        app.tabBars.buttons["Body"].tap()
        let chest = element(app, "body.weeklySets.chest")
        scroll(app.collectionViews.firstMatch, to: chest)
        XCTAssertTrue(chest.label.contains("of 12 to 20 sets this week"), chest.label)
        app.tabBars.buttons["Today"].tap()
        openTargets(app)
        XCTAssertEqual(element(app, "targets.value.chest").label, "12\u{2013}20 sets")
    }

    private func openTargets(_ app: XCUIApplication) {
        app.buttons["today.settings"].tapCenter()
        let link = app.buttons["settings.weeklyTargets"]
        scroll(app.collectionViews.firstMatch, to: link)
        link.tap()
        XCTAssertTrue(element(app, "targets.value.chest").waitForExistence(timeout: 5))
    }

    func testStreakChipOnTodayAndStreakCardOnLog() {
        let app = launch()
        let chip = element(app, "today.streak")
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertEqual(chip.label, "Weekly streak: 5 weeks. 3 of 4 workouts this week.")
        app.tabBars.buttons["Log"].tap()
        let card = element(app, "log.streak")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.label.contains("Longest: 5 weeks."), card.label)
        screenshot(app, "log-streak")
    }

    func testFinishingTheWeeksLastWorkoutCelebratesOnSummary() {
        let app = launch()
        app.startWorkout()
        app.openExercise("0025")
        app.buttons["logging.logAll"].tapCenter()
        let skipRest = app.buttons["logging.rest.skip"]
        if skipRest.waitForExistence(timeout: 3) { skipRest.tap() }
        app.buttons["logging.next"].tapCenter()
        app.buttons["workout.finish"].tapCenter()
        let discard = app.buttons["finish.discardEmpty"]
        if discard.waitForExistence(timeout: 3) { discard.tap() }
        XCTAssertTrue(app.staticTexts["summary.title"].waitForExistence(timeout: 5))
        let celebration = element(app, "summary.weekComplete")
        XCTAssertTrue(celebration.waitForExistence(timeout: 5))
        XCTAssertTrue(celebration.label.contains("Week complete"), celebration.label)
        XCTAssertTrue(celebration.label.contains("6-week streak"), celebration.label)
        let chest = app.staticTexts["summary.weekly.chest"]
        XCTAssertTrue(chest.exists)
        XCTAssertTrue(chest.label.hasPrefix("Chest ") && chest.label.hasSuffix("/10\u{2013}20 this week"), chest.label)
        screenshot(app, "summary-week-complete")
    }
}
