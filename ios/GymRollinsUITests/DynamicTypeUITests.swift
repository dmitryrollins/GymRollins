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

    /// The bottom bar stacks Start above Build, and both stay reachable, with the gym chip on Today.
    func testTodayBottomBarAndGymChipAtAccessibilityXL() {
        let app = launch(extra: ["-seedGym"])
        let start = app.buttons["today.start"], build = app.buttons["today.build"]
        XCTAssertTrue(build.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isHittable)
        XCTAssertTrue(build.isHittable)
        XCTAssertLessThanOrEqual(start.frame.maxY, build.frame.minY + 1, "Start stacks above Build workout")
        XCTAssertGreaterThanOrEqual(build.frame.height, 44)
        let chip = app.buttons["today.gymChip"]
        XCTAssertTrue(chip.exists)
        XCTAssertTrue(chip.label.contains("Home"), chip.label)
        XCTAssertGreaterThanOrEqual(chip.frame.height, 44)
        screenshot("today-gym-ax-xl")
    }

    /// At accessibility sizes the workout pill takes its own full row under Settings, My Plan and the day picker.
    /// VoiceOver still reads the date.
    func testTodayHeaderAtAccessibilityXL() {
        let app = launch()
        let header = TodayHeaderElements(app)
        XCTAssertTrue(header.workout.waitForExistence(timeout: 5))
        screenshot("today-header-ax-xl")
        XCTAssertEqual(header.myPlan.frame.midY, header.settings.frame.midY, accuracy: 4, header.description)
        XCTAssertEqual(header.date.frame.midY, header.settings.frame.midY, accuracy: 4, header.description)
        XCTAssertGreaterThanOrEqual(header.workout.frame.minY, header.settings.frame.maxY, header.description)
        header.assertOnScreen(app)
        XCTAssertTrue(header.date.label.contains("26"), "label was '\(header.date.label)'")
    }

    /// The header stays at the top while Today scrolls under it (owner, 2026-11-19).
    func testTodayHeaderStaysAtTheTop() {
        let app = launch(size: "UICTContentSizeCategoryL")
        let header = TodayHeaderElements(app)
        let recovery = app.descendants(matching: .any)["today.recovery"].firstMatch
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        let pill = header.workout.frame, card = recovery.frame
        app.swipeUp()
        app.swipeUp()
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 1) // the screenshot after the fling
        screenshot("today-header-scrolled")
        XCTAssertLessThan(recovery.frame.minY, card.minY - 100, "Today didn't scroll")
        XCTAssertEqual(header.workout.frame, pill)
        for element in [header.settings, header.workout, header.myPlan, header.date] {
            XCTAssertTrue(element.isHittable, header.description)
        }
    }

    /// Below accessibility sizes the header is one row like the reference design (owner, 2026-11-18): Settings, the workout
    /// pill, then My Plan and the day picker sharing one pill, all on screen.
    func testTodayHeaderIsOneRow() {
        for name in ["L", "XL", "XXL", "XXXL"] {
            let size = "UICTContentSizeCategory\(name)"
            let app = launch(size: size)
            let header = TodayHeaderElements(app)
            XCTAssertTrue(header.workout.waitForExistence(timeout: 5))
            screenshot("today-header-\(name)")
            XCTAssertEqual(header.workout.frame.midY, header.settings.frame.midY, accuracy: 4, "\(size): \(header)")
            XCTAssertEqual(header.date.frame.midY, header.settings.frame.midY, accuracy: 4, "\(size): \(header)")
            XCTAssertGreaterThanOrEqual(header.workout.frame.minX, header.settings.frame.maxX, "\(size): \(header)")
            XCTAssertGreaterThanOrEqual(header.myPlan.frame.minX, header.workout.frame.maxX, "\(size): \(header)")
            header.assertOnScreen(app)
            XCTAssertEqual(header.workout.label, "Push + Arms \u{00B7} 7 exercises")
            XCTAssertEqual(header.workout.value as? String, "Today")
            XCTAssertTrue(header.date.label.contains("26"), "\(size): label was '\(header.date.label)'")
            app.terminate()
        }
    }

    /// My Plan's day rows stay inside the screen and every day can be reached at the largest text size.
    func testMyPlanWeekAtAccessibilityXL() {
        let app = launch()
        app.buttons["today.myPlan"].tap()
        let monday = app.buttons["plan.day.1"]
        XCTAssertTrue(monday.waitForExistence(timeout: 5))
        screenshot("my-plan-ax-xl")
        let width = app.windows.firstMatch.frame.width
        for weekday in 1...7 {
            let row = app.buttons["plan.day.\(weekday)"]
            app.scrollToHittable(row)
            XCTAssertTrue(row.isHittable, "day \(weekday)")
            XCTAssertLessThanOrEqual(row.frame.maxX, width + 0.5, "day \(weekday) \(row.frame)")
        }
        app.buttons["plan.day.1"].tap()
        XCTAssertTrue(app.buttons["day.workout"].waitForExistence(timeout: 5))
        screenshot("day-editor-ax-xl")
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

    func testSharedWorkoutSheetsAtAccessibilityXL() throws {
        let app = launch()
        let share = app.buttons["today.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        for _ in 0..<10 where !share.isHittable { app.swipeUp() }
        XCTAssertTrue(share.isHittable, "Share workout can be reached")
        share.tap()
        XCTAssertTrue(app.images["share.qr"].waitForExistence(timeout: 10))
        let send = app.descendants(matching: .any)["share.send"]
        for _ in 0..<6 where !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.isHittable, "Send link can be reached")
        screenshot("share-workout-ax-xl")
        app.buttons["share.done"].tap()
        XCTAssertTrue(app.images["share.qr"].waitForNonExistence(timeout: 5))

        app.open(try XCTUnwrap(URL(string: "gymrollins://w#1.0025_3_8-10.0313_3_10")))
        let use = app.buttons["incoming.use"]
        XCTAssertTrue(use.waitForExistence(timeout: 10))
        XCTAssertTrue(use.isHittable, "Use for today can be reached")
        XCTAssertTrue(app.buttons["incoming.notNow"].isHittable, "Not now can be reached")
        screenshot("incoming-workout-ax-xl")
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

    func testReportSheetAtAccessibilityXL() {
        let app = launch(extra: ["-fakeGymCatalog", "-fakeSignedIn"])
        app.buttons["today.gymChip"].tap()
        XCTAssertTrue(app.buttons["gymPicker.currentEquipment"].waitForExistence(timeout: 5))
        app.buttons["gymPicker.currentEquipment"].tap()
        XCTAssertTrue(app.staticTexts["gymEquipment.coverage.chest"].waitForExistence(timeout: 15))
        // Plan 40's taller section labels leave the lat pulldown's row of the lazy grid just below the fold at this
        // size, where it isn't built until scrolled to.
        let tile = app.buttons["gymEquipment.listing.lat-pulldown"]
        app.scrollToHittable(tile)
        tile.tapWhenHittable()
        let menu = app.buttons["listing.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(menu.isHittable)
        menu.tap()
        app.buttons["listing.report"].tap()
        let send = app.buttons["report.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let reason = app.buttons["report.reason.person-in-photo"]
        for _ in 0..<4 where !reason.isHittable { app.swipeUp() }
        XCTAssertTrue(reason.isHittable)
        XCTAssertGreaterThanOrEqual(reason.frame.height, 44)
        screenshot("report-sheet-ax-xl")
        reason.tap()
        for _ in 0..<4 where !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.isHittable)
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
    }

    func testSharingScreensAtAccessibilityXL() {
        let app = launch(extra: ["-fakeGymCatalog", "-gymPhotoFixture"])
        app.buttons["today.gymChip"].tap()
        XCTAssertTrue(app.buttons["gymPicker.currentEquipment"].waitForExistence(timeout: 5))
        app.buttons["gymPicker.currentEquipment"].tap()
        XCTAssertTrue(app.buttons["gymEquipment.listing.lat-pulldown"].waitForExistence(timeout: 15))
        screenshot("shared-gym-equipment-ax-xl")
        let barbell = app.buttons["gymEquipment.listing.barbell"]
        for _ in 0..<8 where !barbell.exists { app.swipeUp() } // tiles below the fold aren't built until scrolled to
        barbell.tapWhenHittable()
        let retry = app.buttons["listing.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        for _ in 0..<4 where !retry.isHittable { app.swipeUp() }
        XCTAssertTrue(retry.isHittable)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        screenshot("listing-couldnt-upload-ax-xl")
        retry.tapCenter()
        XCTAssertTrue(element(app, "signInForSharing.title").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["signInForSharing.cancel"].isHittable)
        screenshot("sign-in-to-share-ax-xl")
        app.buttons["signInForSharing.cancel"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["gymEquipment.add"].tap()
        app.buttons["addEquipment.skip"].tapWhenHittable()
        let search = app.textFields["addEquipment.kindSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap()
        // Two words leave one tile, at the top: at this size "lat" alone puts the lat pulldown in the second row, where
        // the bar above the keyboard covers its middle and takes the tap.
        search.typeText("lat pull")
        app.buttons["addEquipment.kind.lat-pulldown"].tapCenter()
        let confirm = app.buttons["add.confirm.00000000-0000-4000-8000-0000000000B1"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        for _ in 0..<4 where !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        screenshot("add-equipment-already-here-ax-xl")
        for _ in 0..<4 where !app.buttons["addEquipment.different"].isHittable { app.swipeUp() }
        app.buttons["addEquipment.different"].tapCenter()
        let shared = app.buttons["add.visibility.shared"]
        XCTAssertTrue(shared.waitForExistence(timeout: 5))
        for _ in 0..<4 where !shared.isHittable { app.swipeUp() }
        XCTAssertTrue(shared.isHittable)
        XCTAssertGreaterThanOrEqual(shared.frame.height, 44)
        screenshot("add-equipment-who-sees-it-ax-xl")
    }

    func testLimitsCheckInAtAccessibilityXL() {
        let app = launch(extra: ["-seedHistory", "-seedLimitsDue"])
        for id in ["limits.yes", "limits.notYet"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            // Toward the button either way: at this size one swipe can carry the second button past the top.
            for _ in 0..<8 where !button.isHittable {
                if button.frame.midY < app.frame.midY { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
            }
            XCTAssertTrue(button.isHittable, id)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, id)
        }
        screenshot("limits-check-in-ax-xl")
    }

    func testLimitsSettingsAtAccessibilityXL() {
        let app = launch()
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.limits"]
        // Above the floating tab bar: a row under it still counts as hittable, and the tap would land on a tab.
        let clearOfTabBar = app.windows.firstMatch.frame.height - 150
        for _ in 0..<8 where !(row.isHittable && row.frame.maxY < clearOfTabBar) { app.swipeUp() }
        row.tapCenter()
        let save = app.buttons["limits.edit.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        for _ in 0..<6 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable)
        XCTAssertGreaterThanOrEqual(save.frame.height, 44)
        screenshot("limits-settings-ax-xl")
    }

    func testClaudeGymsToggleAtAccessibilityXL() {
        let app = launch()
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.claude"]
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tapCenter()
        let gyms = app.switches["claude.perm.readGyms"]
        XCTAssertTrue(app.staticTexts["claude.status"].waitForExistence(timeout: 5))
        for _ in 0..<12 where !gyms.isHittable { app.swipeUp() } // rows below the fold aren't built until scrolled to
        XCTAssertTrue(gyms.isHittable)
        XCTAssertGreaterThanOrEqual(gyms.frame.height, 44)
        screenshot("claude-gyms-ax-xl")
        let note = app.staticTexts["claude.gymsNote"]
        for _ in 0..<6 where !note.isHittable { app.swipeUp() }
        XCTAssertTrue(note.exists)
    }

    func testUseWithClaudeAtAccessibilityXL() {
        let app = launch()
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.claude"]
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tapCenter()
        XCTAssertTrue(app.staticTexts["claude.status"].waitForExistence(timeout: 5))
        let coach = app.buttons["claude.coach.copy"]
        for _ in 0..<20 where !coach.isHittable { app.swipeUp() } // below the switches since plan 32
        XCTAssertTrue(coach.isHittable)
        XCTAssertGreaterThanOrEqual(coach.frame.height, 44)
        screenshot("claude-coach-ax-xl")
    }

    /// Plan 32: an agent's row and Add workouts stay readable and tappable at AX-XL.
    func testAgentsAtAccessibilityXL() {
        let app = launch(extra: ["-seedHistory", "-fakeAgents"])
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.claude"]
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tapCenter()
        let name = app.staticTexts["agents.name.MuseFakeClientId"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let disconnect = app.buttons["agents.disconnect.MuseFakeClientId"]
        for _ in 0..<6 where !disconnect.isHittable { app.swipeUp() }
        XCTAssertTrue(disconnect.isHittable)
        XCTAssertGreaterThanOrEqual(disconnect.frame.height, 44)
        XCTAssertTrue(app.staticTexts["agents.lastUsed.MuseFakeClientId"].exists)
        screenshot("agents-ax-xl")

        let add = app.switches["agents.perm.logWorkouts"]
        for _ in 0..<20 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.isHittable)
        XCTAssertGreaterThanOrEqual(add.frame.height, 44)
        screenshot("agents-add-workouts-ax-xl")
    }

    func testModerationAtAccessibilityXL() {
        let app = launch(extra: ["-fakeGymCatalog", "-fakeSignedIn", "-fakeGymAdmin"])
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.moderation"]
        for _ in 0..<6 where !row.isHittable { app.swipeUp() } // rows below the fold aren't built until scrolled to
        XCTAssertTrue(row.isHittable)
        row.tapCenter()
        let id = "00000000-0000-4000-8000-0000000000D1"
        let restore = app.buttons["moderation.restore.\(id)"]
        XCTAssertTrue(restore.waitForExistence(timeout: 10))
        for _ in 0..<4 where !restore.isHittable { app.swipeUp() }
        XCTAssertTrue(restore.isHittable)
        XCTAssertGreaterThanOrEqual(restore.frame.height, 44)
        screenshot("moderation-ax-xl")
        let remove = app.buttons["moderation.remove.\(id)"]
        for _ in 0..<4 where !remove.isHittable { app.swipeUp() }
        XCTAssertGreaterThanOrEqual(remove.frame.height, 44)
        remove.tapCenter()
        let confirm = app.buttons["moderation.removeConfirm.\(id)"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        for _ in 0..<4 where !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        XCTAssertGreaterThanOrEqual(confirm.frame.height, 44)
        screenshot("moderation-confirm-ax-xl")
    }
}

/// Today's header: Settings, the workout pill, and My Plan and the day picker.
private struct TodayHeaderElements: CustomStringConvertible {
    let settings, workout, myPlan, date: XCUIElement

    init(_ app: XCUIApplication) {
        settings = app.buttons["today.settings"]
        workout = app.descendants(matching: .any)["today.workout"].firstMatch
        myPlan = app.buttons["today.myPlan"]
        date = app.buttons["today.date"]
    }

    var description: String {
        "settings \(settings.frame), workout \(workout.frame), My Plan \(myPlan.frame), date \(date.frame)"
    }

    /// Every part is inside the screen's width and at least a tap target tall.
    func assertOnScreen(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for element in [settings, workout, myPlan, date] {
            XCTAssertGreaterThanOrEqual(element.frame.minX, 0, description, file: file, line: line)
            XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX, description, file: file, line: line)
            XCTAssertGreaterThanOrEqual(element.frame.height, 43.5, description, file: file, line: line) // 44 pt, rounded
        }
    }
}
