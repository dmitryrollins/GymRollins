import XCTest

/// Apple Watch (plan 17): `-fakeWatch` replaces WatchConnectivity with an in-process watch that runs the watch app's
/// real view model; its buttons (`watch.fake.*`) send the same commands the watch would.
final class WatchUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func probe(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["watch.fake.probe"] }

    private func wait(_ element: XCUIElement, label predicate: String, _ value: String, file: StaticString = #filePath,
                      line: UInt = #line) {
        let match = NSPredicate(format: "label \(predicate) %@", value)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: match, object: element)], timeout: 5)
        XCTAssertEqual(result, .completed, "label is '\(element.label)', expected \(predicate) '\(value)'",
                       file: file, line: line)
    }

    func testLogSetFromTheWatchLogsItOnThePhone() {
        let app = XCUIApplication.launchReady(["-seedHistory", "-fakeWatch"]) { $0.buttons["today.start"] }
        app.startWorkout()
        app.openExercise("0025")
        wait(probe(app), label: "BEGINSWITH", "Warm-up 1/2 · 45 lb × 10")
        XCTAssertTrue(probe(app).label.contains("launches 1"), probe(app).label) // the watch workout was woken

        // Digital Crown: one loadable step heavier, one rep fewer — then Log set on the watch.
        app.buttons["watch.fake.crownUp"].tap()
        app.buttons["watch.fake.repsDown"].tap()
        XCTAssertFalse(probe(app).label.contains("45×10"), probe(app).label)
        app.buttons["watch.fake.logSet"].tap()

        let first = app.descendants(matching: .any)["logging.set.0.summary"]
        wait(first, label: "ENDSWITH", ", done")
        XCTAssertTrue(first.label.hasPrefix("Warm-up set 1, 9 reps, "), first.label)
        XCTAssertFalse(first.label.contains(" 45 pounds"), first.label)
        // The phone's state came back: next set, rest running.
        wait(probe(app), label: "BEGINSWITH", "Warm-up 2/2")
        XCTAssertTrue(probe(app).label.contains(" · rest · "), probe(app).label)
    }

    func testStartTodaysWorkoutFromTheWatch() {
        let app = XCUIApplication.launchReady(["-seedHistory", "-fakeWatch"]) { $0.buttons["today.start"] }
        wait(probe(app), label: "BEGINSWITH", "idle")
        app.buttons["watch.fake.startToday"].tap()
        app.buttons["today.resume"].tapCenter()
        XCTAssertTrue(app.staticTexts["workout.clock"].waitForExistence(timeout: 10), "workout didn't open")
        wait(probe(app), label: "BEGINSWITH", "Warm-up 1/2")
    }
}
