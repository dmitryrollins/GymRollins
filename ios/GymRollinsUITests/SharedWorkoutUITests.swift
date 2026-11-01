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
}
