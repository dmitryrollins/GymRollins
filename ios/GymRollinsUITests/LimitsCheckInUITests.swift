import XCTest

/// The injury note's end date: editing it in Settings, and the check-in card on Today.
@MainActor
final class LimitsCheckInUITests: XCTestCase {
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

    private func openLimitsSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        scrollAndTap(app, app.buttons["settings.limits"])
        XCTAssertTrue(element(app, "limits.edit.note").waitForExistence(timeout: 5))
    }

    private func replaceNote(_ app: XCUIApplication, with text: String) {
        let field = element(app, "limits.edit.note")
        field.tap()
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
        XCTAssertTrue(chip.label.hasPrefix("Shoulder: no overhead pressing"), chip.label)

        app.tabBars.buttons["Log"].tap()
        scrollAndTap(app, app.buttons["settings.limits"])
        scrollAndTap(app, app.buttons["limits.edit.clear"])
        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "today.limits").exists)
    }
}
