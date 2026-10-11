import XCTest

/// Shared launch and tap helpers that remove two sources of flakiness seen in long suite runs.
///
/// 1. Launch readiness. Right after `launch()` the app's accessibility server can still be coming up; the first
///    query then fails with `kAXErrorServerNotFound` ("error getting main window"). `launchReady` waits for the
///    process to be `runningForeground` and for a known first-screen element to exist before the test touches
///    anything, and makes sure a previous instance is fully gone first.
/// 2. Bottom-bar glass buttons. `PrimaryGlassButton`s live in a `.safeAreaInset(edge: .bottom)` bar, under which
///    iOS 26 draws a scroll-edge dimming overlay that is itself an accessibility element. While that overlay covers
///    the button's centre, XCUITest's hit-point search can settle on the button's frame corner (seen: (21, 782) for
///    a 20…382 × 713…783 frame), which lies outside the rounded capsule, so the touch lands on nothing and the tap
///    is silently lost. `tapCenter` sends the touch to the visual centre, where the button always wins UIKit
///    hit-testing (the overlay isn't interactive).
extension XCUIApplication {
    static let fixedNow = "2026-09-26T09:00:00Z"

    /// Launches with `-uiTesting -fixedNow <fixedNow>` plus `extra`, and returns once the app is in the foreground
    /// and `firstElement` (resolved against the launched app) exists.
    static func launchReady(_ extra: [String] = [], fixedNow: String = fixedNow,
                            firstElement: (XCUIApplication) -> XCUIElement = { $0.tabBars.firstMatch },
                            file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-fixedNow", fixedNow] + extra
        app.launchReady(firstElement: firstElement(app), file: file, line: line)
        return app
    }

    /// Launches with the arguments already set on this instance (see `launchReady(_:fixedNow:firstElement:)`).
    func launchReady(firstElement: XCUIElement? = nil, file: StaticString = #filePath, line: UInt = #line) {
        if state != .notRunning {
            terminate()
            XCTAssertTrue(wait(for: .notRunning, timeout: 10), "previous instance still running", file: file, line: line)
        }
        launch()
        XCTAssertTrue(wait(for: .runningForeground, timeout: 20), "app never reached the foreground", file: file, line: line)
        let first = firstElement ?? tabBars.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20), "first screen never appeared", file: file, line: line)
    }

    /// Taps Today's "Start Workout" and waits for the in-progress workout's clock.
    func startWorkout(file: StaticString = #filePath, line: UInt = #line) {
        buttons["today.start"].tapCenter(file: file, line: line)
        XCTAssertTrue(staticTexts["workout.clock"].waitForExistence(timeout: 10), "workout didn't open",
                      file: file, line: line)
    }

    /// From the workout overview, opens the logging screen for `exerciseId`.
    func openExercise(_ exerciseId: String, file: StaticString = #filePath, line: UInt = #line) {
        let entry = buttons["workout.entry.\(exerciseId)"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "no entry \(exerciseId)", file: file, line: line)
        entry.tap()
        XCTAssertTrue(staticTexts["logging.title"].waitForExistence(timeout: 5), "logging didn't open",
                      file: file, line: line)
    }
}

extension XCUIElement {
    /// Waits for the element, then taps its visual centre (see the type comment above for why).
    func tapCenter(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "missing \(self)", file: file, line: line)
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}

extension XCUIApplication {
    /// Taps a chip on the exercise screen's chip row ("logging.chip.swap"…). The row scrolls sideways, so chips
    /// past the screen edge are scrolled into view first.
    func tapLoggingChip(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let chip = buttons[identifier]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "missing \(identifier)", file: file, line: line)
        let screen = windows.firstMatch.frame
        for _ in 0..<3 where !screen.contains(chip.frame) {
            buttons["logging.chip.history"].swipeLeft()
        }
        chip.tap()
    }
}
