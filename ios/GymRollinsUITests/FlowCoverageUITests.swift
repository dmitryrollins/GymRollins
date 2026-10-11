import XCTest

/// Gap tests from the flow-map coverage matrix (`docs/testing/flow-coverage.md`): one test per flow-map step that
/// had no UI coverage, named after the step. 26 Sep 2026 is a Saturday, so Today shows Push + Arms (bench 0025
/// first). With `-seedHistory` the bench session is 2 warm-ups + 3 working sets at 135 lb.
final class FlowCoverageUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    // MARK: 3.3 Rest timer settings

    /// Changing the working and warm-up durations in the rest sheet sets the chip and the next rests' length.
    /// `-fixedNow` freezes the clock, so the rest bar shows the full duration.
    func testStep3_3RestSettingsChangeTheNextRestDuration() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.startWorkout()
        app.openExercise("0025")

        app.buttons["logging.chip.rest"].tap()
        let wheel = app.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        wheel.adjust(toPickerWheelValue: "3:00")
        app.buttons["Warm-up sets"].tap()
        wheel.adjust(toPickerWheelValue: "2:15")
        app.buttons["rest.done"].tapCenter()
        XCTAssertTrue(app.buttons["rest.done"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["logging.chip.rest"].label.contains("3:00 rest"), app.buttons["logging.chip.rest"].label)

        // Two warm-ups rest 2:15 each, then the first working set rests 3:00.
        // The rest readout is one accessibility element whose value is the spoken remaining time (the clock is fixed).
        for expected in ["2 minutes 15 seconds", "2 minutes 15 seconds", "3 minutes"] {
            app.buttons["logging.logSet"].tapCenter()
            XCTAssertTrue(app.buttons["logging.rest.skip"].waitForExistence(timeout: 5))
            let rest = app.descendants(matching: .any)["logging.rest"]
            XCTAssertTrue(rest.waitForExistence(timeout: 3))
            XCTAssertEqual(rest.value as? String, "\(expected) remaining")
            app.buttons["logging.rest.skip"].tap()
            XCTAssertTrue(app.buttons["logging.logSet"].waitForExistence(timeout: 5))
        }
    }

    // MARK: 3.5 How-to

    func testStep3_5HowToOpensFromLogging() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.startWorkout()
        app.openExercise("0025")

        app.buttons["logging.howto"].tap()
        let title = app.staticTexts["detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Barbell Bench Press")
        XCTAssertTrue(app.buttons["Instructions"].exists)
        XCTAssertFalse(app.staticTexts["No instructions for this exercise yet."].exists)
    }

    // MARK: 3.7 Exercise options: notes

    /// A note typed in the exercise options sheet is saved with the in-progress workout and is still there after
    /// the app is killed and the workout resumed.
    func testStep3_7ExerciseNotePersistsAfterRelaunch() {
        let note = "Elbows tucked, pause on chest"
        var app = XCUIApplication.launchReady(["-seedHistory", "-diskStore", "-resetStore"]) { $0.buttons["today.start"] }
        app.startWorkout()
        app.openExercise("0025")

        app.buttons["logging.options"].tap()
        let field = noteField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(note)
        app.buttons["Cancel"].tapCenter() // "Cancel" closes the sheet and keeps the note
        XCTAssertTrue(noteField(app).waitForNonExistence(timeout: 5))
        app.terminate()

        app = XCUIApplication.launchReady(["-diskStore"]) { $0.buttons["today.resume"] }
        app.buttons["today.resume"].tapCenter()
        app.openExercise("0025")
        app.buttons["logging.options"].tap()
        let reopened = noteField(app)
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertEqual(reopened.value as? String, note)
    }

    /// The options sheet's other actions: "Add warm-up set" adds a set to the exercise, "Remove from workout" drops it.
    func testStep3_7ExerciseOptionsAddWarmupAndRemove() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.startWorkout()
        let benchCount = app.staticTexts["workout.entry.0025.count"]
        XCTAssertTrue(benchCount.waitForExistence(timeout: 5))
        XCTAssertEqual(benchCount.label, "0/5")

        app.openExercise("0025")
        app.buttons["logging.options"].tap()
        app.buttons["options.addWarmup"].tapCenter()
        XCTAssertTrue(app.buttons["options.addWarmup"].waitForNonExistence(timeout: 5))
        app.buttons["logging.close"].tap()
        XCTAssertTrue(benchCount.waitForExistence(timeout: 5))
        XCTAssertEqual(benchCount.label, "0/6")

        app.openExercise("0025")
        app.buttons["logging.options"].tap()
        app.buttons["options.remove"].tapCenter()
        XCTAssertTrue(app.buttons["workout.entry.0025"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["workout.clock"].exists) // back on the overview, workout still running
    }

    /// The multi-line notes `TextField` surfaces as a text view or a text field depending on its content.
    private func noteField(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "options.note").firstMatch
    }

    // MARK: 4.2 Workout detail: share

    func testStep4_2WorkoutDetailSharesTheWorkout() {
        let app = XCUIApplication.launchReady(["-seedHistory"])
        app.tabBars.buttons["Log"].tap()
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        cards.firstMatch.tap()

        let share = app.buttons["detail.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tapCenter()
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 10))
        // The share preview carries the workout's text summary (name, date, duration, sets).
        let caption = app.otherElements["LP.CaptionBar.BottomCaption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertTrue(caption.label.hasPrefix("Push + Biceps \u{2014} Sat 19 Sep, 58 min"), caption.label)
        XCTAssertTrue(caption.label.contains("Barbell Bench Press"), caption.label)
        // On this SDK the sheet has no "Close" button; tapping outside it dismisses it.
        app.otherElements["PopoverDismissRegion"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(shareSheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(share.exists) // back on the detail screen
    }

    // MARK: 5.2 Custom exercise in a routine and a workout

    /// A custom exercise created in Library can be added to a routine, shows on Today, and is logged in a workout.
    func testStep5_2CustomExerciseIsUsableInRoutineAndWorkout() {
        let name = "Zeta Band Press"
        let app = XCUIApplication.launchReady()
        app.tabBars.buttons["Library"].tap()
        app.buttons["library.add"].tap()
        let nameField = app.textFields["custom.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(name)
        app.buttons["custom.save"].tap()
        XCTAssertTrue(nameField.waitForNonExistence(timeout: 5))

        // Add it to today's routine.
        app.tabBars.buttons["Today"].tap()
        app.buttons["today.myPlan"].tap()
        let routine = app.buttons["plan.routine.Push + Arms"]
        XCTAssertTrue(routine.waitForExistence(timeout: 5))
        routine.tap()
        let addExercise = app.buttons["edit.addExercise"]
        XCTAssertTrue(app.steppers["edit.sets.0025"].waitForExistence(timeout: 5))
        swipeUntilExists(addExercise, in: app)
        addExercise.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("zeta band")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'picker.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains(name), row.label)
        let customId = String(row.identifier.dropFirst("picker.row.".count))
        row.tap()
        app.navigationBars["Add Exercise"].buttons["Close"].tap() // ends the search session (restores "Add")
        app.buttons["picker.add"].tap()
        let editRow = app.descendants(matching: .any)["edit.row.\(customId)"]
        swipeUntilExists(editRow, in: app)
        XCTAssertTrue(editRow.exists)
        app.buttons["edit.done"].tap()
        app.navigationBars.buttons.firstMatch.tap() // back to Today

        let todayRow = app.descendants(matching: .any)["today.row.\(customId)"]
        swipeUntilExists(todayRow, in: app)
        XCTAssertTrue(todayRow.label.contains(name), todayRow.label)

        // Log it in a workout.
        app.startWorkout()
        let entry = app.buttons["workout.entry.\(customId)"]
        swipeUntilExists(entry, in: app)
        app.openExercise(customId)
        XCTAssertEqual(app.staticTexts["logging.title"].label, name)
        app.buttons["logging.logSet"].tapCenter()
        XCTAssertTrue(app.buttons["logging.rest.skip"].waitForExistence(timeout: 5))
        app.buttons["logging.rest.skip"].tap()
        app.buttons["logging.close"].tap()
        let count = app.staticTexts["workout.entry.\(customId).count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue(count.label.hasPrefix("1/"), count.label)
    }

    // MARK: 4.3 Exercise history + e1RM trend

    func testStep4_3ExerciseHistoryShowsTheE1RMTrend() {
        let app = XCUIApplication.launchReady(["-seedHistory"])
        app.tabBars.buttons["Body"].tap()
        let lift = app.buttons["body.lift.0025"]
        XCTAssertTrue(lift.waitForExistence(timeout: 5))
        lift.tap()
        // History tab: past sessions, newest first.
        XCTAssertTrue(app.staticTexts["3 \u{00D7} 10 @ 130 lb (59 kg)"].waitForExistence(timeout: 5))
        app.buttons["Trends"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["history.chart"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["EST. 1RM"].exists) // SectionLabel uppercases
    }

    // MARK: 4.4 Body: goal + trends

    /// Five weekly weigh-ins (81.0 → 81.8 kg) give a chart, goal progress and a weekly trend line.
    func testStep4_4BodyShowsGoalProgressAndTrend() {
        let app = XCUIApplication.launchReady(["-seedBodyweight"])
        app.tabBars.buttons["Body"].tap()
        let trend = app.staticTexts["body.trend"]
        XCTAssertTrue(trend.waitForExistence(timeout: 5))
        XCTAssertTrue(trend.label.contains("kg / week"), trend.label)
        XCTAssertTrue(app.descendants(matching: .any)["body.chart"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["body.progress"].exists)
        XCTAssertFalse(app.staticTexts["body.empty"].exists)
    }

    // MARK: Helpers

    /// Lazily realized list rows only enter the accessibility tree once scrolled near.
    private func swipeUntilExists(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 12,
                                  file: StaticString = #filePath, line: UInt = #line) {
        var swipes = 0
        while !element.exists && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(element.waitForExistence(timeout: 3), "never found \(element)", file: file, line: line)
    }
}
