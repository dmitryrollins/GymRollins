import XCTest

/// "Reps left?" chips: after the last working set of an exercise is logged, one optional row of 0 · 1 · 2 · 3 · 4+ chips appears under it.
/// One tap stores the rating on that set (it survives leaving and reopening the exercise), tapping the selected chip
/// clears it, and none of it touches the running rest. Barbell Bench Press (0025) starts with two warm-ups, so set
/// index 2 is the first working set. The chips screenshot is attached as "set-effort-chips".
final class SetEffortUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func chip(_ app: XCUIApplication, _ n: Int) -> XCUIElement { app.buttons["set.effort.\(n)"] }

    func testRateALoggedSetWithOneTap() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.startWorkout()
        app.openExercise("0025")

        // Warm-ups are never rated.
        for _ in 0..<2 {
            app.buttons["logging.logSet"].tapCenter()
            app.buttons["logging.rest.skip"].tapCenter()
        }
        XCTAssertFalse(chip(app, 2).exists, "no chips for warm-ups")

        // Asked once per exercise: not after the first two working sets…
        for _ in 0..<2 {
            app.buttons["logging.logSet"].tapCenter()
            XCTAssertFalse(chip(app, 2).waitForExistence(timeout: 1), "no chips while sets remain")
            app.buttons["logging.rest.skip"].tapCenter()
            XCTAssertTrue(app.buttons["logging.logSet"].waitForExistence(timeout: 5), "rest skipped")
        }
        // …only after the last one (no rest follows an exercise's last set).
        app.buttons["logging.logSet"].tapCenter()
        XCTAssertTrue(chip(app, 2).waitForExistence(timeout: 3))
        XCTAssertEqual(chip(app, 2).label, "2 reps left")
        XCTAssertEqual(chip(app, 4).label, "4 or more reps left")
        XCTAssertFalse(chip(app, 2).isSelected)

        chip(app, 2).tap()
        XCTAssertTrue(chip(app, 2).isSelected)
        XCTAssertFalse(chip(app, 3).isSelected)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "set-effort-chips"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Stored on the set: leave the exercise and come back.
        app.buttons["logging.close"].tap()
        app.openExercise("0025")
        XCTAssertTrue(chip(app, 2).waitForExistence(timeout: 3))
        XCTAssertTrue(chip(app, 2).isSelected)

        // Tapping the selected chip clears it.
        chip(app, 2).tap()
        XCTAssertFalse(chip(app, 2).isSelected)
        chip(app, 0).tap()
        XCTAssertTrue(chip(app, 0).isSelected)
    }

    /// Editable later: Log → workout → Edit shows the same chips per working set; Save stores the rating.
    func testRateASetWhenEditingAPastWorkout() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.tabBars.buttons["Log"].tap()
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        cards.firstMatch.tap()
        app.buttons["detail.menu"].tapCenter()
        app.buttons["detail.edit"].tapCenter()

        let chip = app.buttons["detail.set.0.0.effort.3"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        XCTAssertTrue(chip.isSelected)
        app.buttons["detail.save"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '\u{00B7} 3 left'")).firstMatch
            .waitForExistence(timeout: 5))
    }
}
