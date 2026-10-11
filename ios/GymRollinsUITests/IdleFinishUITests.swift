import XCTest

/// Finishing long after the last set (the owner forgot to tap Finish): the finish flow offers ending at the last set,
/// and the summary's duration follows that choice instead of counting the idle time.
final class IdleFinishUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Sets are logged at the fixed 09:00 in a workout started at 08:40; the app comes back at 10:27 (a relaunch
    /// with a later `-fixedNow`) and the workout is finished then.
    func testFinishLongAfterTheLastSetEndsAtTheLastSet() {
        var app = XCUIApplication.launchReady(["-seedHistory", "-diskStore", "-resetStore",
                                               "-workoutStartedMinutesAgo", "20"]) { $0.buttons["today.start"] }
        app.startWorkout()
        app.openExercise("0025")
        app.buttons["logging.logAll"].tapCenter()
        XCTAssertTrue(app.buttons["logging.next"].waitForExistence(timeout: 5)) // the sets are saved
        app.terminate()

        app = XCUIApplication.launchReady(["-diskStore"], fixedNow: "2026-09-26T10:27:00Z") {
            $0.buttons["today.resume"]
        }
        app.buttons["today.resume"].tapCenter()
        app.buttons["workout.finish"].tapCenter()

        let message = app.staticTexts["finish.idleMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(message.label, "Your last set was 1 h 27 min ago")
        XCTAssertTrue(app.buttons["finish.endNow"].exists)
        let endAtLastSet = app.buttons["finish.endAtLastSet"]
        XCTAssertTrue(endAtLastSet.label.hasPrefix("End at "), endAtLastSet.label)
        endAtLastSet.tap()

        // Other exercises are still undone: the usual choices follow, for the chosen end.
        XCTAssertTrue(app.buttons["finish.discardEmpty"].waitForExistence(timeout: 3))
        app.buttons["finish.discardEmpty"].tap()

        assertShortSummary(app)
    }

    /// Every set done: Finish has no undone-sets sheet, so the idle question is asked on its own.
    func testDirectFinishWithAllSetsDoneAsksToo() {
        var app = XCUIApplication.launchReady(["-seedHistory", "-diskStore", "-resetStore",
                                               "-workoutStartedMinutesAgo", "20"]) { $0.buttons["today.start"] }
        app.startWorkout()
        let entries = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workout.entry.'"))
        XCTAssertTrue(entries.firstMatch.waitForExistence(timeout: 10))
        let ids = entries.allElementsBoundByIndex.map { $0.identifier }
            .map { $0.replacingOccurrences(of: "workout.entry.", with: "") }
            .filter { !$0.contains(".") }
        XCTAssertFalse(ids.isEmpty)
        for (index, id) in ids.enumerated() {
            app.openExercise(id)
            app.buttons["logging.logAll"].tapCenter()
            if index < ids.count - 1 { app.buttons["logging.next"].tapCenter() }
        }
        XCTAssertTrue(app.buttons["workout.finish"].waitForExistence(timeout: 5)) // the last exercise is done
        app.terminate()

        app = XCUIApplication.launchReady(["-diskStore"], fixedNow: "2026-09-26T10:27:00Z") {
            $0.buttons["today.resume"]
        }
        app.buttons["today.resume"].tapCenter()
        app.buttons["workout.finish"].tapCenter()

        XCTAssertTrue(app.staticTexts["finish.idleMessage"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["finish.discardEmpty"].exists)
        app.buttons["finish.endAtLastSet"].tap()
        assertShortSummary(app)
    }

    /// 20 min before the sets + one rest: well under an hour ("m:ss"), not 1:47:00.
    private func assertShortSummary(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts["summary.title"].waitForExistence(timeout: 5), file: file, line: line)
        let duration = app.staticTexts["summary.duration"].label
        XCTAssertEqual(duration.filter { $0 == ":" }.count, 1, duration, file: file, line: line)
        XCTAssertTrue(duration.hasPrefix("2"), duration, file: file, line: line)
    }
}
