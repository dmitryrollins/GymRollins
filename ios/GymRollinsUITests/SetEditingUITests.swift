import XCTest

/// Set list editing on the exercise screen: swipe a set left to delete it, and a new weight or reps value on one set
/// carries to the later sets still to do. Barbell Bench Press (0025) starts with two warm-ups, so index 2 is the first working set.
final class SetEditingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func openBench() -> XCUIApplication {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.startWorkout()
        app.openExercise("0025")
        return app
    }

    private func summary(_ app: XCUIApplication, _ index: Int) -> XCUIElement {
        app.descendants(matching: .any)["logging.set.\(index).summary"]
    }

    func testSwipeASetLeftToDeleteIt() {
        let app = openBench()
        XCTAssertTrue(summary(app, 4).waitForExistence(timeout: 5))
        XCTAssertFalse(summary(app, 5).exists, "expected 2 warm-ups + 3 working sets")

        // A short drag reveals the Delete button; tapping it deletes the set.
        let row = app.textFields["logging.set.4.reps"]
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -110, dy: 0)))
        let delete = app.buttons["logging.set.4.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3), "short drag shows Delete")
        delete.tap()
        XCTAssertTrue(summary(app, 4).waitForNonExistence(timeout: 3), "the set is gone")

        // A long swipe deletes straight away.
        let weight = app.textFields["logging.set.3.weight"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        weight.press(forDuration: 0.05, thenDragTo: weight.withOffset(CGVector(dx: -280, dy: 0)))
        XCTAssertTrue(summary(app, 3).waitForNonExistence(timeout: 3), "long swipe deletes")
        XCTAssertTrue(summary(app, 2).exists)
    }

    func testANewWeightCarriesToTheLaterSets() {
        let app = openBench()
        let first = app.textFields["logging.set.2.weight"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.clearAndType("150")
        app.dismissKeyboardIfPresent()
        XCTAssertEqual(app.textFields["logging.set.3.weight"].value as? String, "150")
        XCTAssertEqual(app.textFields["logging.set.4.weight"].value as? String, "150")
        XCTAssertNotEqual(app.textFields["logging.set.1.weight"].value as? String, "150", "warm-ups keep their ramp")
    }

    func testNewRepsCarryToTheLaterSets() {
        let app = openBench()
        let first = app.textFields["logging.set.2.reps"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let before = app.textFields["logging.set.3.reps"].value as? String
        XCTAssertNotEqual(before, "12", "the test needs a start other than 12")
        first.clearAndType("12")
        // Live: the later sets follow while the box is still being edited, before Done.
        XCTAssertEqual(app.textFields["logging.set.3.reps"].value as? String, "12")
        app.dismissKeyboardIfPresent()
        XCTAssertEqual(app.textFields["logging.set.3.reps"].value as? String, "12")
        XCTAssertEqual(app.textFields["logging.set.4.reps"].value as? String, "12")
    }

    func testKeyboardNextMovesToTheNextBox() {
        let app = openBench()
        let reps = app.textFields["logging.set.1.reps"]
        XCTAssertTrue(reps.waitForExistence(timeout: 5))
        reps.tap()
        let previous = app.buttons["keyboard.previous"]
        XCTAssertTrue(previous.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["keyboard.next"].isEnabled)
        app.buttons["keyboard.next"].tap()
        // The next box in a set's order is its weight; typing lands there.
        let weight = app.textFields["logging.set.1.weight"]
        app.typeText("77")
        XCTAssertTrue((weight.value as? String)?.contains("77") == true, "typed into the next box")
        XCTAssertTrue(app.buttons["keyboard.done"].exists)
        XCTAssertTrue(previous.isEnabled)
        assertBarSitsAboveTheKeys(app)

        app.buttons["keyboard.done"].tap()
        XCTAssertTrue(app.buttons["keyboard.done"].waitForNonExistence(timeout: 3), "Done closes the bar")
    }

    /// The bar floats `KeyboardBar.gap` (6 pt) above the keys instead of touching them. Checked only when the software
    /// keyboard shows: with a hardware keyboard there are no keys to measure against.
    private func assertBarSitsAboveTheKeys(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let keys = app.keyboards.firstMatch
        guard keys.exists else { return }
        let done = app.buttons["keyboard.done"].frame
        XCTAssertLessThanOrEqual(done.maxY, keys.frame.minY - 4, "Done at \(done), keys at \(keys.frame)",
                                 file: file, line: line)
    }
}
