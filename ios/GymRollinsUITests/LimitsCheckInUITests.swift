import XCTest

/// The injury note's end date: editing it in Settings, and the check-in card on Today.
@MainActor
final class LimitsCheckInUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    /// Same figure as `AccessibilityAuditUITests.bottomEdgeBand`: the floating tab bar and Today's Start Workout bar
    /// cover the bottom of the window, and a row there can report `isHittable` while the tap lands on the bar.
    private static let bottomEdgeBand: CGFloat = 165

    private func isClearOfBars(_ app: XCUIApplication, _ button: XCUIElement) -> Bool {
        button.isHittable && button.frame.maxY < app.windows.firstMatch.frame.height - Self.bottomEdgeBand
    }

    /// Scrolls until `button` can take a touch clear of the bottom bars, then taps it.
    private func scrollAndTap(_ app: XCUIApplication, _ button: XCUIElement, file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertTrue(button.waitForExistence(timeout: 10), "missing \(button)", file: file, line: line)
        for _ in 0..<8 where !isClearOfBars(app, button) { app.swipeUp() }
        XCTAssertTrue(isClearOfBars(app, button), "\(button) can't be reached", file: file, line: line)
        button.tap()
    }

    private func openLimitsSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        scrollAndTap(app, app.buttons["settings.limits"])
        XCTAssertTrue(element(app, "limits.edit.note").waitForExistence(timeout: 5))
    }

    private func replaceNote(_ app: XCUIApplication, with text: String) {
        let field = element(app, "limits.edit.note")
        field.tap()
        // A plain tap can leave the caret mid-text, and then the deletes miss the end of the old note.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80) + text)
    }

    func testANoteWithNoDateShowsAsBefore() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        XCTAssertEqual(element(app, "today.limits").label, "Knee: no leg loading until ~26 Oct 2026")
        XCTAssertFalse(element(app, "limits.card").exists)
    }

    func testEditAndClearInSettings() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        openLimitsSettings(app)
        replaceNote(app, with: "Shoulder: no overhead pressing")
        app.switches["limits.edit.note.hasDate"].tap()
        XCTAssertTrue(element(app, "limits.edit.note.until").waitForExistence(timeout: 5))
        scrollAndTap(app, app.buttons["limits.edit.save"])
        XCTAssertTrue(app.buttons["settings.limits"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Today"].tap()
        let chip = element(app, "today.limits")
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(chip.label.hasPrefix("Shoulder: no overhead pressing \u{00B7} until "), chip.label)

        app.tabBars.buttons["Log"].tap()
        scrollAndTap(app, app.buttons["settings.limits"])
        scrollAndTap(app, app.buttons["limits.edit.clear"])
        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "today.limits").exists)
    }

    func testTurningUntilBackOnOverAPastDateStartsFromALaterOne() {
        let app = XCUIApplication.launchReady(["-seedLimitsDue"]) { $0.buttons["today.start"] }
        XCTAssertTrue(element(app, "limits.card").waitForExistence(timeout: 5))
        openLimitsSettings(app)
        let toggle = app.switches["limits.edit.note.hasDate"]
        toggle.tap()
        XCTAssertFalse(element(app, "limits.edit.note.until").exists)
        toggle.tap()
        XCTAssertTrue(element(app, "limits.edit.note.until").waitForExistence(timeout: 5))
        scrollAndTap(app, app.buttons["limits.edit.save"])
        XCTAssertTrue(app.buttons["settings.limits"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Today"].tap()
        let chip = element(app, "today.limits")
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(chip.label.hasPrefix("Knee: no leg loading \u{00B7} until "), chip.label)
        XCTAssertFalse(element(app, "limits.card").exists)
    }

    func testNotYetMovesTheDate() {
        let app = XCUIApplication.launchReady(["-seedLimitsDue"]) { $0.buttons["today.start"] }
        let question = element(app, "limits.question")
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        XCTAssertTrue(question.label.hasPrefix("You planned this until "), question.label)
        XCTAssertFalse(element(app, "today.limits").exists)
        scrollAndTap(app, app.buttons["limits.notYet"])
        XCTAssertTrue(element(app, "limits.nextDate").waitForExistence(timeout: 5))
        scrollAndTap(app, app.buttons["limits.saveDate"])
        let chip = element(app, "today.limits")
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(chip.label.hasPrefix("Knee: no leg loading \u{00B7} until "), chip.label)
        XCTAssertFalse(element(app, "limits.card").exists)
    }

    func testYesThenResumeLegsThenOpenMyPlan() {
        let app = XCUIApplication.launchReady(["-seedLimitsDue"]) { $0.buttons["today.start"] }
        scrollAndTap(app, app.buttons["limits.yes"])
        let resume = app.buttons["limits.resume.0"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertEqual(resume.label, "Resume Legs at 60%")
        XCTAssertFalse(element(app, "today.limits").exists)
        scrollAndTap(app, resume)
        let message = element(app, "limits.resumed")
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(message.label, "Legs is back, with 6 exercises at 60%. Pick its day in My Plan.")
        scrollAndTap(app, app.buttons["limits.openPlan"])
        XCTAssertTrue(element(app, "plan.routine.Legs").waitForExistence(timeout: 5))
    }

    func testNotNowClosesTheCardAndLeavesTheNoteCleared() {
        let app = XCUIApplication.launchReady(["-seedLimitsDue"]) { $0.buttons["today.start"] }
        scrollAndTap(app, app.buttons["limits.yes"])
        scrollAndTap(app, app.buttons["limits.notNow"])
        XCTAssertFalse(element(app, "limits.card").waitForExistence(timeout: 2))
        XCTAssertFalse(element(app, "today.limits").exists)
    }

    func testNoCardDuringAWorkout() {
        let app = XCUIApplication.launchReady(["-seedLimitsDue"]) { $0.buttons["today.start"] }
        app.startWorkout()
        XCTAssertTrue(app.buttons["workout.close"].waitForExistence(timeout: 5))
        app.buttons["workout.close"].tap()
        XCTAssertTrue(element(app, "today.resumeBanner").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "limits.card").exists)
        XCTAssertTrue(element(app, "today.limits").exists)
    }
}
