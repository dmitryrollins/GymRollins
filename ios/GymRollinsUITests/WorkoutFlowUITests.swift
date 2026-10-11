import XCTest

final class WorkoutFlowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        XCUIApplication.launchReady(["-seedHistory"] + extra) { $0.buttons["today.start"] }
    }

    func testFullWorkoutWithRestPlatesAndRecords() {
        let app = launch()
        app.startWorkout()
        app.openExercise("0025")
        XCTAssertEqual(app.staticTexts["logging.title"].label, "Barbell Bench Press")

        // Warm-up 1 logged -> rest bar appears with a warm-up duration
        app.buttons["logging.logSet"].tapCenter()
        XCTAssertTrue(app.descendants(matching: .any)["logging.rest"].waitForExistence(timeout: 3))
        app.buttons["logging.rest.skip"].tap()

        // Plate calculator for the 135 lb working weight: 45 lb bar + one 45 lb plate each side
        app.buttons["logging.chip.plates"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["plates.side.45"].waitForExistence(timeout: 3))
        // `app.swipeDown()` synthesizes its drag from the whole-app frame, which starts above a
        // `.medium`-height sheet and never reaches its dismiss gesture; anchoring a manual drag to
        // a control inside the sheet (here "Done") reliably swipes it down instead.
        let plateSheetDrag = app.buttons["plates.done"].coordinate(withNormalizedOffset: CGVector(dx: -3, dy: 1))
        let plateSheetDragEnd = app.buttons["plates.done"].coordinate(withNormalizedOffset: CGVector(dx: -3, dy: 30))
        plateSheetDrag.press(forDuration: 0.05, thenDragTo: plateSheetDragEnd)
        // Waits for the dismiss animation to finish so the set timeline below is hittable again.
        XCTAssertTrue(app.buttons["plates.done"].waitForNonExistence(timeout: 3))

        // Beat last session: 10 reps at 135 on every working set -> records. Consecutive rows are
        // edited on the same screen; see testEditConsecutiveFieldsWithoutLeavingScreen.
        for index in 2...4 {
            app.textFields["logging.set.\(index).reps"].clearAndType("10")
        }
        app.dismissKeyboardIfPresent()
        app.buttons["logging.logAll"].tapCenter()
        app.buttons["logging.next"].tapCenter()

        app.buttons["workout.finish"].tapCenter()
        XCTAssertTrue(app.buttons["finish.discardEmpty"].waitForExistence(timeout: 3))
        app.buttons["finish.discardEmpty"].tap()

        XCTAssertTrue(app.staticTexts["summary.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["summary.sets"].label, "3")
        XCTAssertTrue(app.descendants(matching: .any)["summary.record.0"].exists)
        app.buttons["summary.done"].tapCenter()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))
    }

    /// Edits reps then weight on one row, then consecutive rows, all on one LoggingView instance
    /// (no leaving the screen), and checks the edits survive logging and reopening the exercise.
    func testEditConsecutiveFieldsWithoutLeavingScreen() {
        let app = launch()
        app.startWorkout()
        // 15 s like the other first-screen waits: under heavy machine load the overview can take longer than 5 s to
        // render its rows (the real cause of this test's failures was a leftover today plan, see TodayPlanLaunchTests).
        XCTAssertTrue(app.buttons["workout.entry.0025"].waitForExistence(timeout: 15))
        app.buttons["workout.entry.0025"].tap()
        XCTAssertTrue(app.staticTexts["logging.title"].waitForExistence(timeout: 5))

        let edits: [(String, String)] = [
            ("logging.set.2.reps", "10"), ("logging.set.2.weight", "140"),
            ("logging.set.3.reps", "10"), ("logging.set.4.reps", "9")
        ]
        for (identifier, text) in edits {
            let field = app.textFields[identifier]
            XCTAssertTrue(field.waitForExistence(timeout: 3), identifier)
            field.clearAndType(text)
            XCTAssertEqual(field.value as? String, text, identifier)
        }
        for (identifier, text) in edits {
            XCTAssertEqual(app.textFields[identifier].value as? String, text, identifier)
        }
        app.dismissKeyboardIfPresent()
        app.buttons["logging.logAll"].tap()

        app.buttons["logging.close"].tap()
        XCTAssertTrue(app.buttons["workout.entry.0025"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["workout.entry.0025.count"].label, "5/5")
        app.buttons["workout.entry.0025"].tap()
        XCTAssertTrue(app.staticTexts["logging.title"].waitForExistence(timeout: 3))
        for (identifier, text) in edits {
            XCTAssertEqual(app.textFields[identifier].value as? String, text, "persisted \(identifier)")
        }
    }

    func testResumeAfterRelaunch() {
        var app = launch(["-diskStore", "-resetStore"])
        app.startWorkout()
        app.openExercise("0025")
        app.buttons["logging.logSet"].tapCenter()
        XCTAssertTrue(app.buttons["logging.rest.skip"].waitForExistence(timeout: 3)) // the set is saved
        app.terminate()

        app = XCUIApplication.launchReady(["-diskStore"]) { $0.buttons["today.resume"] }
        app.buttons["today.resume"].tapCenter()
        XCTAssertTrue(app.staticTexts["workout.entry.0025.count"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["workout.entry.0025.count"].label, "1/5")
    }

    func testSwapAndAddExerciseAndDiscard() {
        let app = launch()
        app.startWorkout()
        app.buttons["workout.entry.0070"].tap()
        app.tapLoggingChip("logging.chip.swap")
        let firstCandidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'swap.row.'")).firstMatch
        XCTAssertTrue(firstCandidate.waitForExistence(timeout: 3))
        firstCandidate.tap()
        app.buttons["logging.close"].tap()
        XCTAssertFalse(app.buttons["workout.entry.0070"].exists)

        app.buttons["workout.addExercise"].tap()
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("chest dip")
        app.buttons["picker.row.0251"].tap()
        // While the search field is actively focused/searching, SwiftUI's .searchable suppresses
        // the toolbar's Cancel/Add items in favor of only its own search-session "Close" button
        // (same SDK behavior already documented in PlanUITests.testEditRoutineAddsExerciseAndChangesSets);
        // tapping it ends the search session and restores the toolbar so "picker.add" is reachable.
        // Scoped to the picker's own navigation bar: unlike that Plan-tab test, the workout
        // overview underneath this sheet has its own "Close" button (`workout.close`), so an
        // unscoped `app.buttons["Close"]` matches both and is ambiguous here.
        app.navigationBars["Add Exercise"].buttons["Close"].tap()
        app.buttons["picker.add"].tap()
        XCTAssertTrue(app.buttons["workout.entry.0251"].waitForExistence(timeout: 3))

        app.buttons["workout.finish"].tap()
        app.buttons["finish.discard"].tap()
        app.buttons["Discard"].tap() // confirmation dialog
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))
    }
}

extension XCUIApplication {
    /// Taps the keyboard toolbar's "Done" (number pads have no return key) when a keyboard is up.
    func dismissKeyboardIfPresent() {
        guard keyboards.firstMatch.exists else { return }
        let done = buttons["keyboard.done"]
        if done.exists { done.tap() }
        _ = keyboards.firstMatch.waitForNonExistence(timeout: 3)
    }
}

extension XCUIElement {
    func clearAndType(_ text: String) {
        revealAboveKeyboard()
        // A plain tap on these center-aligned reps/weight boxes can leave the cursor before the
        // existing short value instead of after it, making the backspaces below a no-op and
        // corrupting the result (e.g. "8" -> "108"). Tapping the field's trailing edge first
        // reliably places the cursor after the last character before clearing it.
        coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        let current = (value as? String) ?? ""
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }

    /// Coordinate taps don't auto-scroll, so when a keyboard is up and would cover this element,
    /// drag the enclosing scroll content up until it clears the keyboard (and its toolbar).
    private func revealAboveKeyboard() {
        let app = XCUIApplication()
        for _ in 0..<4 {
            let keyboard = app.keyboards.firstMatch
            guard keyboard.exists, frame.maxY > keyboard.frame.minY - 60 else { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)))
        }
    }
}
