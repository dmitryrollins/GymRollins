import XCTest

/// Set list editing on the exercise screen: swipe a set left to delete it, and a new weight on one set carries to
/// the later sets still to do. Barbell Bench Press (0025) starts with two warm-ups, so index 2 is the first working set.
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
}
