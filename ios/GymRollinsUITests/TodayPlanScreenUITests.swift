import XCTest

/// Tapping an exercise on Today opens the same exercise screen as inside a workout, in plan mode: today's sets are
/// edited there (same `logging.*` identifiers), the edits survive a relaunch the same day, and Start Workout starts
/// today's workout on that exercise. Barbell Bench Press (0025) is planned 3 × 8–10 @ 140 lb with two generated
/// warm-ups, so set index 3 is working "Set 2". Screenshots are attached as "plan-screen-*".
final class TodayPlanScreenUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "plan-screen-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(_ extra: [String], fixedNow: String = "2026-09-26T09:00:00Z") -> XCUIApplication {
        XCUIApplication.launchReady(extra, fixedNow: fixedNow) { $0.buttons["today.start"] }
    }

    private func field(_ app: XCUIApplication, _ index: Int, _ kind: String) -> XCUIElement {
        app.textFields["logging.set.\(index).\(kind)"]
    }

    private func openBench(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons["today.row.0025"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
        row.tap()
        XCTAssertTrue(app.buttons["logging.startWorkout"].waitForExistence(timeout: 5), "plan screen opened",
                      file: file, line: line)
    }

    private func type(_ app: XCUIApplication, _ index: Int, _ kind: String, _ text: String) {
        field(app, index, kind).clearAndType(text)
        app.buttons["keyboard.done"].tap()
    }

    private func setRest(_ app: XCUIApplication, _ value: String) {
        app.buttons["logging.chip.rest"].tap()
        let wheel = app.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Warm-up sets"].exists, "today's rest is for working sets")
        wheel.adjust(toPickerWheelValue: value)
        app.buttons["rest.done"].tapCenter()
        XCTAssertTrue(app.buttons["rest.done"].waitForNonExistence(timeout: 5))
    }

    func testEditOnThePlanScreenKeepsTheEditsAndStartsOnThatExercise() {
        var app = launch(["-diskStore", "-resetStore"])
        screenshot(app, "1-today")
        openBench(app)
        screenshot(app, "2-plan")
        XCTAssertTrue(app.staticTexts["logging.title"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["logging.clock"].exists, "no workout clock before the start")
        XCTAssertFalse(app.buttons["logging.logSet"].exists)
        XCTAssertFalse(app.buttons["logging.edited"].exists)
        XCTAssertFalse(app.staticTexts["logging.edited"].exists)
        XCTAssertEqual(field(app, 3, "weight").value as? String, "140")

        type(app, 3, "weight", "150")
        type(app, 3, "reps", "7")
        XCTAssertEqual(field(app, 3, "weight").value as? String, "150")
        XCTAssertEqual(field(app, 3, "reps").value as? String, "7")
        app.buttons["logging.addSet"].tap()
        XCTAssertTrue(field(app, 5, "weight").waitForExistence(timeout: 5), "a fourth working set")
        setRest(app, "2:30")
        XCTAssertTrue(app.buttons["logging.chip.rest"].label.contains("2:30 rest"), app.buttons["logging.chip.rest"].label)
        XCTAssertTrue(app.descendants(matching: .any)["logging.edited"].exists, "the hero says Edited")
        screenshot(app, "3-plan-edited")

        app.buttons["logging.close"].tap()
        let row = app.buttons["today.row.0025"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Edited"), row.label)
        XCTAssertTrue(row.label.contains("4 \u{00D7} 7\u{2013}8"), row.label)
        screenshot(app, "4-today-edited")
        app.terminate()

        app = launch(["-diskStore"])
        openBench(app)
        XCTAssertEqual(field(app, 3, "weight").value as? String, "150", "edits survive a relaunch the same day")
        XCTAssertEqual(field(app, 3, "reps").value as? String, "7")
        XCTAssertTrue(field(app, 5, "weight").exists)
        XCTAssertTrue(app.buttons["logging.chip.rest"].label.contains("2:30 rest"))

        app.buttons["logging.startWorkout"].tapCenter()
        XCTAssertTrue(app.descendants(matching: .any)["logging.clock"].waitForExistence(timeout: 10),
                      "the workout opens on this exercise")
        XCTAssertTrue(app.buttons["logging.logSet"].exists)
        XCTAssertTrue(app.staticTexts["logging.title"].label.contains("Bench"), app.staticTexts["logging.title"].label)
        XCTAssertEqual(field(app, 3, "weight").value as? String, "150")
        XCTAssertEqual(field(app, 3, "reps").value as? String, "7")
        XCTAssertTrue(app.buttons["logging.chip.rest"].label.contains("2:30 rest"))
        screenshot(app, "5-workout-started")

        app.buttons["logging.close"].tap() // back to the workout overview
        XCTAssertTrue(app.staticTexts["workout.entry.0025.count"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["workout.entry.0025.count"].label, "0/6")
        app.buttons["workout.close"].tap()
        XCTAssertTrue(app.buttons["today.resume"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["today.row.0025"].tap()
        XCTAssertFalse(app.buttons["logging.startWorkout"].waitForExistence(timeout: 2),
                       "no plan screen while the workout runs")
    }

    func testResetAndReplaceFromThePlanScreen() {
        let app = launch([])
        openBench(app)
        type(app, 3, "weight", "150")
        XCTAssertTrue(app.descendants(matching: .any)["logging.edited"].waitForExistence(timeout: 5))

        app.buttons["logging.options"].tap()
        let reset = app.buttons["Reset to Suggested"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()
        XCTAssertTrue(app.descendants(matching: .any)["logging.edited"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(field(app, 3, "weight").value as? String, "140", "back to the suggestion")

        app.buttons["logging.options"].tap()
        let replace = app.buttons["Replace"]
        XCTAssertTrue(replace.waitForExistence(timeout: 5))
        replace.tap()
        let candidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'swap.row.'")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        let newId = candidate.identifier.replacingOccurrences(of: "swap.row.", with: "")
        candidate.tap()
        XCTAssertTrue(app.buttons["logging.startWorkout"].waitForExistence(timeout: 5), "still on the plan screen")
        XCTAssertFalse(app.staticTexts["logging.title"].label.contains("Bench Press"),
                       app.staticTexts["logging.title"].label)

        app.buttons["logging.close"].tap()
        XCTAssertTrue(app.buttons["today.row.\(newId)"].waitForExistence(timeout: 5), "replaced for today")
        XCTAssertFalse(app.buttons["today.row.0025"].exists)
        XCTAssertTrue(app.staticTexts["today.summary"].label.contains("edited for today"),
                      app.staticTexts["today.summary"].label)
    }

    /// How-To from the plan screen opens the exercise's details on top, and Back returns to the plan screen (it used
    /// to slide the details in under the plan screen, so the same screen showed again and Back revealed How-To).
    func testHowToFromThePlanScreenOpensOnTopAndBackReturns() {
        let app = launch([])
        openBench(app)
        app.buttons["logging.howto"].tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5), "How-To opened")
        XCTAssertFalse(app.buttons["logging.startWorkout"].isHittable, "the plan screen is underneath")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["logging.startWorkout"].waitForExistence(timeout: 5), "back on the plan screen")
        XCTAssertTrue(app.staticTexts["detail.title"].waitForNonExistence(timeout: 5))
        app.buttons["logging.close"].tap()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5), "and back to Today")
    }

    func testBadgeMenuRemovesASetAndMakesAWarmup() {
        let app = launch([])
        openBench(app)
        let setTwo = app.descendants(matching: .any)["logging.set.3.summary"]
        XCTAssertTrue(setTwo.waitForExistence(timeout: 5))
        XCTAssertEqual(setTwo.label, "Set 2, 8 reps, 140 pounds", "planned: no done / current status")

        setTwo.press(forDuration: 1.0)
        let makeWarmup = app.buttons["Make Warm-up Set"]
        XCTAssertTrue(makeWarmup.waitForExistence(timeout: 5))
        makeWarmup.tap()
        XCTAssertTrue(app.descendants(matching: .any)["logging.set.3.summary"].label.hasPrefix("Warm-up set 3"))

        app.descendants(matching: .any)["logging.set.0.summary"].press(forDuration: 1.0)
        let remove = app.buttons["Remove Set"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(field(app, 4, "weight").waitForNonExistence(timeout: 5), "four sets left")
        XCTAssertTrue(app.descendants(matching: .any)["logging.edited"].exists)
    }

    func testSaveChangesWritesThePlanScreenEditsIntoTheRoutine() {
        var app = launch(["-diskStore", "-resetStore"])
        openBench(app)
        type(app, 3, "weight", "150")
        app.buttons["logging.addSet"].tap()
        app.buttons["logging.close"].tap()
        let save = app.buttons["today.saveToRoutine"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5), "saved: nothing left to save")
        app.terminate()

        // A week later the routine itself plans four working sets at the saved weight.
        app = launch(["-diskStore"], fixedNow: "2026-10-03T09:00:00Z")
        let row = app.buttons["today.row.0025"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("4 \u{00D7} 8\u{2013}10"), row.label)
        XCTAssertTrue(row.label.contains("150 lb"), row.label)
    }
}
