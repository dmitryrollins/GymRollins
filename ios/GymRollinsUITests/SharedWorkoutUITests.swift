import XCTest

/// Workout links opened the way iOS opens them (`XCUIApplication.open`), and the Share button on each screen.
@MainActor
final class SharedWorkoutUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    /// Scrolls until `button` can take a touch, then taps it.
    private func scrollAndTap(_ app: XCUIApplication, _ button: XCUIElement, file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertTrue(button.waitForExistence(timeout: 10), "missing \(button)", file: file, line: line)
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable, "\(button) can't be reached", file: file, line: line)
        button.tap()
    }

    private func expectShareScreen(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.images["share.qr"].waitForExistence(timeout: 10), "no QR code", file: file, line: line)
        XCTAssertTrue(element(app, "share.send").exists, "no Send link", file: file, line: line)
        XCTAssertEqual(app.staticTexts["share.note"].label, "Your partner sees this workout with their own weights.",
                       file: file, line: line)
        app.buttons["share.done"].tap()
        XCTAssertTrue(app.images["share.qr"].waitForNonExistence(timeout: 5), "the sheet didn't close",
                      file: file, line: line)
    }

    func testShareFromToday() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        scrollAndTap(app, app.buttons["today.share"])
        expectShareScreen(app)
    }

    func testShareFromTheBuildResult() {
        let app = XCUIApplication.launchReady(["-seedGym"]) { $0.buttons["today.gymChip"] }
        app.buttons["today.build"].tapCenter()
        XCTAssertTrue(app.buttons["build.go"].waitForExistence(timeout: 5))
        // The sheet remembers the last chips and length, so set them.
        for chip in ["chest", "back", "shoulders", "arms", "legs", "core"] {
            let button = app.buttons["build.chip.\(chip)"]
            if button.isSelected != (chip == "back") { button.tap() }
        }
        app.buttons["build.length.60"].tap()
        app.buttons["build.go"].tapCenter()
        XCTAssertTrue(element(app, "build.title").waitForExistence(timeout: 10))
        scrollAndTap(app, app.buttons["build.share"])
        expectShareScreen(app)
    }

    func testShareFromTheRunningWorkout() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.startWorkout()
        scrollAndTap(app, app.buttons["workout.share"])
        expectShareScreen(app)
    }

    private let benchAndCurl = URL(string: "gymrollins://w#1.0025_3_8-10.0313_3_10")!

    private func opened(_ url: URL) -> XCUIApplication {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.open(url)
        return app
    }

    /// Spec criteria 1 and 5: their own weights on the sheet, then on Today and in the workout.
    func testALinkBecomesTodaysPlan() {
        let app = opened(benchAndCurl)
        XCTAssertTrue(app.buttons["incoming.use"].waitForExistence(timeout: 10), "the sheet didn't open")
        XCTAssertEqual(app.staticTexts["incoming.count"].label, "2 exercises")
        XCTAssertTrue(element(app, "incoming.row.0025").label.contains("lb"), element(app, "incoming.row.0025").label)
        app.buttons["incoming.use"].tapCenter()
        XCTAssertTrue(app.buttons["incoming.use"].waitForNonExistence(timeout: 5))
        let summary = app.staticTexts["today.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        let shared = NSPredicate(format: "label CONTAINS 'Shared workout'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: shared, object: summary)], timeout: 5),
                       .completed, summary.label)
        app.startWorkout()
        XCTAssertTrue(app.buttons["workout.entry.0025"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workout.entry.0313"].exists)
        XCTAssertFalse(app.buttons["workout.entry.0194"].exists, "the seeded routine's triceps exercise is still there")
    }

    func testNotNowLeavesTodayAlone() {
        let app = opened(benchAndCurl)
        let before = app.staticTexts["today.summary"].label
        XCTAssertTrue(app.buttons["incoming.notNow"].waitForExistence(timeout: 10))
        app.buttons["incoming.notNow"].tapCenter()
        XCTAssertTrue(app.buttons["incoming.notNow"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["today.summary"].label, before)
    }

    /// Spec criterion 2.
    func testANewExerciseSaysSetOnFirstSet() {
        let app = XCUIApplication.launchReady(["-emptyStore", "-skipOnboarding"]) { $0.staticTexts["today.summary"] }
        app.open(benchAndCurl)
        let row = element(app, "incoming.row.0025")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Set on first set"), row.label)
    }

    func testACardioTargetShowsItsMinutes() {
        let app = opened(URL(string: "gymrollins://w#1.3220_1_s600")!)
        let row = element(app, "incoming.row.3220")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("10 min"), row.label)
    }

    /// Spec criterion 6.
    func testADamagedLinkSaysSoAndChangesNothing() {
        let app = opened(URL(string: "gymrollins://w#nonsense")!)
        let message = app.staticTexts["incoming.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertEqual(message.label, "This link doesn't work. Ask for a new one.")
        XCTAssertFalse(app.buttons["incoming.use"].exists)
        app.buttons["incoming.close"].tapCenter()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["today.summary"].label.contains("Shared workout"))
    }

    func testANewerLinkAsksForAnUpdate() {
        let app = opened(URL(string: "gymrollins://w#2.anything")!)
        let message = app.staticTexts["incoming.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertEqual(message.label, "Update GymRollins to open this workout.")
    }

    func testSaysWhenAnExerciseIsMissing() {
        let app = opened(URL(string: "gymrollins://w#1.0025_3_10.ZZZZ_3_10")!)
        let notice = app.staticTexts["incoming.dropped"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(notice.label, "1 exercise isn't in your version of the app.")
    }

    // `XCUIApplication.open` relaunches the app (a new process, and the UI tests' in-memory store is gone), so it can't put a
    // link in front of something on screen. `XCUIDevice.shared.system.open` hands it to the running app, as a tap in Messages
    // does. The workout test below would lose its workout if that weren't so.

    /// Spec criterion 7. The sheet opens over the full-screen workout, and Resume goes back to it.
    func testALinkDuringAWorkoutChangesNothing() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.startWorkout()
        XCUIDevice.shared.system.open(benchAndCurl)
        let message = app.staticTexts["incoming.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10), "the sheet didn't open over the workout")
        XCTAssertEqual(message.label, "Finish your current workout first.")
        app.buttons["incoming.resume"].tapCenter()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["workout.clock"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workout.entry.0194"].waitForExistence(timeout: 5), "the workout changed")
    }

    /// Resume from Today, where the workout's closed: it opens.
    func testResumeOpensAClosedWorkout() {
        let app = XCUIApplication.launchReady(["-seedHistory", "-diskStore", "-resetStore"]) { $0.buttons["today.start"] }
        app.startWorkout()
        app.buttons["workout.close"].tap()
        XCTAssertTrue(element(app, "today.resumeBanner").waitForExistence(timeout: 5))
        // `open` relaunches the app: the workout has to survive that, and the store mustn't be wiped again.
        app.launchArguments.removeAll { $0 == "-resetStore" }
        app.open(benchAndCurl)
        XCTAssertTrue(app.buttons["incoming.resume"].waitForExistence(timeout: 10))
        app.buttons["incoming.resume"].tapCenter()
        XCTAssertTrue(app.staticTexts["workout.clock"].waitForExistence(timeout: 5), "the workout didn't open")
    }

    func testASecondLinkReplacesTheFirst() {
        let app = opened(benchAndCurl)
        XCTAssertTrue(element(app, "incoming.row.0313").waitForExistence(timeout: 10))
        XCUIDevice.shared.system.open(URL(string: "gymrollins://w#1.0194_3_10")!)
        XCTAssertTrue(element(app, "incoming.row.0194").waitForExistence(timeout: 10), "the second link didn't show")
        XCTAssertFalse(element(app, "incoming.row.0313").exists)
    }

    /// Two links hand-over-fist (a QR scan and a message): one sheet, and Not now closes it with nothing left underneath.
    func testTwoLinksInARowLeaveOneSheetThatCloses() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        XCUIDevice.shared.system.open(benchAndCurl)
        XCUIDevice.shared.system.open(URL(string: "gymrollins://w#1.0194_3_10")!)
        XCTAssertTrue(element(app, "incoming.row.0194").waitForExistence(timeout: 15), "the second link didn't show")
        XCTAssertFalse(element(app, "incoming.row.0313").exists)
        app.buttons["incoming.notNow"].tapCenter()
        XCTAssertTrue(app.buttons["incoming.notNow"].waitForNonExistence(timeout: 5), "a sheet was left underneath")
        XCTAssertFalse(app.buttons["incoming.use"].exists)
    }

    /// Use for today with Settings pushed on Today: the plan shows, not Settings.
    func testUseForTodayClosesAPushedScreen() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.buttons["today.settings"].tapCenter()
        XCTAssertFalse(app.staticTexts["today.summary"].exists, "Settings didn't open")
        XCUIDevice.shared.system.open(benchAndCurl)
        XCTAssertTrue(app.buttons["incoming.use"].waitForExistence(timeout: 10))
        app.buttons["incoming.use"].tapCenter()
        let summary = app.staticTexts["today.summary"]
        let shared = NSPredicate(format: "label CONTAINS 'Shared workout' AND isHittable == true")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: shared, object: summary)], timeout: 10),
                       .completed, "Today didn't come back: \(summary.label)")
    }

    /// A partner with no routine has no "No plan yet" over a shared workout, and a way out of it.
    func testASharedWorkoutWithNoRoutinesHasNoEmptyStateAndASwitch() {
        let app = XCUIApplication.launchReady(["-emptyStore", "-skipOnboarding"]) { $0.staticTexts["today.summary"] }
        XCTAssertTrue(app.staticTexts["today.empty.title"].exists)
        app.open(benchAndCurl)
        XCTAssertTrue(app.buttons["incoming.use"].waitForExistence(timeout: 10))
        app.buttons["incoming.use"].tapCenter()
        XCTAssertTrue(app.buttons["today.switch"].waitForExistence(timeout: 10), "no way out of the shared workout")
        XCTAssertFalse(app.staticTexts["today.empty.title"].exists, "No plan yet is over the shared workout")
    }

    /// A first-time partner finishes onboarding, then sees the workout.
    func testALinkWaitsForOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-onboarding", "-fixedNow", XCUIApplication.fixedNow]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.skip"].waitForExistence(timeout: 10))
        XCUIDevice.shared.system.open(benchAndCurl)
        XCTAssertTrue(app.buttons["onboarding.skip"].waitForExistence(timeout: 10), "onboarding wasn't brought back")
        XCTAssertFalse(app.buttons["incoming.use"].waitForExistence(timeout: 3), "the sheet opened over onboarding")
        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(app.buttons["setup.continue"].waitForExistence(timeout: 5))
        let bodyweight = app.textFields["setup.bodyweight"]
        bodyweight.tap()
        bodyweight.typeText("180")
        app.dismissKeyboardIfPresent()
        app.buttons["setup.continue"].tap()
        XCTAssertTrue(app.buttons["import.skip"].waitForExistence(timeout: 5))
        app.buttons["import.skip"].tap()
        XCTAssertTrue(app.buttons["onboarding.later"].waitForExistence(timeout: 5))
        app.buttons["onboarding.later"].tap()
        XCTAssertTrue(app.buttons["incoming.use"].waitForExistence(timeout: 10), "the sheet didn't open after onboarding")
    }
}
