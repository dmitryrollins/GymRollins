import XCTest

/// The logging screen and Today at an accessibility text size (AX-XL). The set boxes stack vertically, and the
/// reps/weight boxes and Log Set stay reachable and working. Screenshots are attached to the result bundle, and also
/// written to `$A11Y_SCREENSHOT_DIR` when set (`TEST_RUNNER_A11Y_SCREENSHOT_DIR=… xcodebuild test …`; the checked-in
/// copies live in docs/screenshots/plan-08/a11y/).
@MainActor
final class DynamicTypeUITests: XCTestCase {
    static let contentSize = "UICTContentSizeCategoryAccessibilityXL"

    override func setUp() { continueAfterFailure = false }

    private func launch(size: String = contentSize, extra: [String] = ["-seedHistory"]) -> XCUIApplication {
        XCUIApplication.launchReady(extra + ["-UIPreferredContentSizeCategoryName", size]) {
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

    // MARK: Gyms

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    /// The bottom bar stacks Start above Build, and both stay reachable; the gym marks wrap instead of clipping.
    func testTodayBottomBarAndGymMarksAtAccessibilityXL() {
        let app = launch(extra: ["-seedGym"])
        let start = app.buttons["today.start"], build = app.buttons["today.build"]
        XCTAssertTrue(build.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isHittable)
        XCTAssertTrue(build.isHittable)
        XCTAssertLessThanOrEqual(start.frame.maxY, build.frame.minY + 1, "Start stacks above Build workout")
        XCTAssertGreaterThanOrEqual(build.frame.height, 44)
        XCTAssertTrue(element(app, "today.gymNote").exists)
        screenshot("today-gym-ax-xl")
    }

    /// The Build sheet remembers its last chips, so leave only `chip` selected.
    private func selectOnly(_ app: XCUIApplication, _ chip: String) {
        for name in ["chest", "back", "shoulders", "arms", "legs", "core"] {
            let button = app.buttons["build.chip.\(name)"]
            for _ in 0..<4 where !button.isHittable { app.swipeUp() }
            if button.isSelected != (name == chip) { button.tap() }
        }
    }

    func testBuildSheetAndResultAtAccessibilityXL() {
        let app = launch(extra: ["-seedGym"])
        app.buttons["today.build"].tapCenter()
        XCTAssertTrue(app.buttons["build.go"].waitForExistence(timeout: 5))
        for chip in ["chest", "back", "shoulders", "arms", "legs", "core"] {
            let button = app.buttons["build.chip.\(chip)"]
            for _ in 0..<4 where !button.isHittable { app.swipeUp() }
            XCTAssertTrue(button.isHittable, "chip \(chip) is reachable")
        }
        selectOnly(app, "back")
        screenshot("build-sheet-ax-xl")
        for _ in 0..<4 where !app.buttons["build.length.60"].isHittable { app.swipeUp() }
        app.buttons["build.length.60"].tap()
        app.buttons["build.go"].tapCenter()
        XCTAssertTrue(element(app, "build.title").waitForExistence(timeout: 10))
        let start = app.buttons["build.start"], rebuild = app.buttons["build.rebuild"]
        XCTAssertTrue(start.isHittable)
        XCTAssertTrue(rebuild.isHittable)
        XCTAssertFalse(start.frame.intersects(rebuild.frame), "Start and Rebuild don't overlap")
        XCTAssertGreaterThanOrEqual(rebuild.frame.height, 44)
        screenshot("build-result-ax-xl")
    }

    func testPickerEquipmentAndAddFlowAtAccessibilityXL() {
        let app = launch(extra: ["-seedGym", "-gymPhotoFixture"])
        app.buttons["today.gymChip"].tap()
        XCTAssertTrue(app.buttons["gymPicker.close"].waitForExistence(timeout: 5))
        screenshot("gym-picker-ax-xl")
        app.buttons["gymPicker.currentEquipment"].tap()
        XCTAssertTrue(app.buttons["gymEquipment.add"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["gymEquipment.add"].isHittable)
        screenshot("gym-equipment-ax-xl")
        app.buttons["gymEquipment.add"].tap()
        XCTAssertTrue(app.buttons["addEquipment.skip"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["addEquipment.library"].isHittable)
        XCTAssertTrue(app.buttons["addEquipment.skip"].isHittable)
        screenshot("add-equipment-ax-xl")
    }
}
