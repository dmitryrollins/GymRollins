import XCTest

/// The workout Live Activity follows the session: `-uiTesting` swaps ActivityKit for an in-memory recorder, and
/// `-liveActivityProbe` shows what the lock screen would show (`RecordingActivityClient.summary`).
final class LiveActivityUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func probe(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["liveActivity.probe"] }

    private func waitForProbe(_ app: XCUIApplication, prefix: String, file: StaticString = #filePath,
                              line: UInt = #line) {
        let match = NSPredicate(format: "label BEGINSWITH %@", prefix)
        let expectation = XCTNSPredicateExpectation(predicate: match, object: probe(app))
        let result = XCTWaiter().wait(for: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed, "probe is '\(probe(app).label)', expected '\(prefix)…'", file: file, line: line)
    }

    func testActivityStartsUpdatesAndEndsWithTheWorkout() {
        let app = XCUIApplication.launchReady(["-seedHistory", "-liveActivityProbe"]) { $0.buttons["today.start"] }
        app.startWorkout()
        waitForProbe(app, prefix: "Warm-up 1/2")
        XCTAssertTrue(probe(app).label.contains("no rest · log · starts 1"), probe(app).label)

        app.openExercise("0025")
        app.buttons["logging.logSet"].tapCenter()
        waitForProbe(app, prefix: "Warm-up 2/2")
        XCTAssertTrue(probe(app).label.contains(" · rest · log · starts 1"), probe(app).label)

        app.buttons["logging.rest.skip"].tap()
        waitForProbe(app, prefix: "Warm-up 2/2")
        XCTAssertTrue(probe(app).label.contains("no rest"), probe(app).label)

        app.buttons["logging.logAll"].tapCenter()
        app.buttons["logging.next"].tapCenter()
        app.buttons["workout.finish"].tapCenter()
        XCTAssertTrue(app.buttons["finish.discardEmpty"].waitForExistence(timeout: 3))
        app.buttons["finish.discardEmpty"].tap()
        XCTAssertTrue(app.staticTexts["summary.title"].waitForExistence(timeout: 5))
        waitForProbe(app, prefix: "none · starts 1")
    }
}
