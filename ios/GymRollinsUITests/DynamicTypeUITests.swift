import XCTest

/// The logging screen and Today at an accessibility text size (AX-XL). The set boxes stack vertically, and the
/// reps/weight boxes and Log Set stay reachable and working. Screenshots are attached to the result bundle, and also
/// written to `$A11Y_SCREENSHOT_DIR` when set (`TEST_RUNNER_A11Y_SCREENSHOT_DIR=… xcodebuild test …`; the checked-in
/// copies live in docs/screenshots/plan-08/a11y/).
@MainActor
final class DynamicTypeUITests: XCTestCase {
    static let contentSize = "UICTContentSizeCategoryAccessibilityXL"

    override func setUp() { continueAfterFailure = false }

    private func launch(size: String = contentSize) -> XCUIApplication {
        XCUIApplication.launchReady(["-seedHistory", "-UIPreferredContentSizeCategoryName", size]) {
            $0.buttons["today.start"]
        }
    }

    private func screenshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["A11Y_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try shot.pngRepresentation.write(to: url)
        } catch {
            XCTFail("couldn't write \(url.path): \(error)")
        }
    }

    func testTodayAndLoggingStayUsableAtAccessibilityXL() {
        let app = launch()
        screenshot("today-ax-xl")

        app.startWorkout()
        app.openExercise("0025")
        screenshot("logging-ax-xl")

        // Boxes stack: the active set's reps box sits above its weight box, both full width.
        let reps = app.textFields["logging.set.0.reps"]
        let weight = app.textFields["logging.set.0.weight"]
        XCTAssertTrue(reps.waitForExistence(timeout: 5))
        XCTAssertTrue(weight.exists)
        XCTAssertLessThanOrEqual(reps.frame.maxY, weight.frame.minY, "reps \(reps.frame) / weight \(weight.frame)")
        XCTAssertEqual(reps.frame.width, weight.frame.width, accuracy: 1)

        // The boxes stay editable.
        reps.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.dismissKeyboardIfPresent()

        // Log Set stays reachable (the bottom bar stacks Log Set above Log All Sets) and logs the set.
        let logSet = app.buttons["logging.logSet"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 5))
        XCTAssertTrue(logSet.isHittable)
        let logAll = app.buttons["logging.logAll"]
        XCTAssertTrue(logAll.exists)
        XCTAssertLessThanOrEqual(logSet.frame.maxY, logAll.frame.minY + 1, "Log Set should stack above Log All Sets")
        logSet.tapCenter()
        XCTAssertTrue(app.buttons["logging.rest.skip"].waitForExistence(timeout: 5))
        screenshot("logging-resting-ax-xl")
    }
}
