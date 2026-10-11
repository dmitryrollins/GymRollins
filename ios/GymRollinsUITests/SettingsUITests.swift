import XCTest

final class SettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"] // Sat: owner's Push + Arms day
        app.launch()
    }

    private func openSettings() {
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
    }

    /// `Form` (a `List`) only materializes rows near the viewport, so a far-down row may not exist in the
    /// accessibility tree at all yet (not just be off-screen) until scrolled closer. Swipe first, then wait.
    private func scrollToHittable(_ element: XCUIElement, maxSwipes: Int = 15) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
    }

    /// A plain `.tap()` on a `Toggle` row in a `Form` doesn't reliably reach the underlying control (its
    /// binding's setter never fires); tap the nested `Switch` when exposed, else a coordinate where the switch
    /// itself renders. Mirrors `ProposalUITests.flip`.
    private func flip(_ toggle: XCUIElement) {
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let before = toggle.value as? String
        let inner = toggle.switches.firstMatch
        if inner.exists { inner.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let changed = NSPredicate(format: "value != %@", before ?? "")
        wait(for: [expectation(for: changed, evaluatedWith: toggle)], timeout: 3)
    }

    /// Switching Units to kg makes Today show the "<n> kg (<n> lb)" style (primary unit first) instead of
    /// "<n> lb (<n> kg)". The exact kg number isn't pinned: a barbell suggestion rounds to the new unit's plate
    /// grid (`ProgressionEngine`/`LoadRounding`), so 140 lb's kg-plate equivalent isn't a bare unit conversion.
    func testSwitchingUnitsToKgChangesTodayDisplay() {
        app.tabBars.buttons["Today"].tap()
        let lbRow = app.staticTexts.containing(NSPredicate(format: "label CONTAINS ' lb (' AND label CONTAINS ' kg)'"))
            .firstMatch
        XCTAssertTrue(lbRow.waitForExistence(timeout: 5))

        openSettings()
        let units = app.buttons["settings.units"]
        XCTAssertTrue(units.waitForExistence(timeout: 5))
        units.tap()
        app.buttons["kg plates"].tap()

        app.tabBars.buttons["Today"].tap()
        let kgRow = app.staticTexts.containing(NSPredicate(format: "label CONTAINS ' kg (' AND label CONTAINS ' lb)'"))
            .firstMatch
        XCTAssertTrue(kgRow.waitForExistence(timeout: 5))
    }

    /// Turning off the 45 lb plate in Bar & Plates changes the combination the plate calculator suggests for
    /// the same 140 lb working set (135 lb of plates per 45+35+10+2.5 arithmetic becomes 35+10+2.5 per side).
    func testPlatesEditorChangeReflectsInPlateCalculator() {
        openSettings()
        let barPlates = app.buttons["settings.barPlates"]
        scrollToHittable(barPlates)
        barPlates.tap()
        flip(app.switches["settings.plates.45"])
        app.navigationBars.buttons.firstMatch.tap() // back to Settings

        app.tabBars.buttons["Today"].tap()
        app.startWorkout()
        XCTAssertTrue(app.staticTexts["workout.clock"].waitForExistence(timeout: 5))
        app.buttons["workout.entry.0025"].tap()

        // 140 lb generates 2 auto warm-ups (bar, then a ~75% ramp) before the working sets; log/skip past both
        // so the plate calculator opens on a 140 lb WORKING set. All 3 working sets share the same target
        // weight, so it's safe to over-shoot by one if there's actually only 1 warm-up.
        for _ in 0..<2 {
            app.buttons["logging.logSet"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["logging.rest"].waitForExistence(timeout: 3))
            app.buttons["logging.rest.skip"].tap()
        }
        app.buttons["logging.chip.plates"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["plates.side.35"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["plates.side.45"].exists)
    }

    /// One tap on "Export all data" builds the JSON backup from current data and presents the system share sheet;
    /// closing it and tapping again builds and shares a fresh file (nothing is cached between taps).
    func testExportAllDataShowsShareSheet() {
        openSettings()
        let export = app.buttons["settings.exportJSON"]
        scrollToHittable(export) // below the Apple Health section
        for _ in 0..<2 {
            export.tap()
            let shareSheet = app.otherElements["ActivityListView"]
            XCTAssertTrue(shareSheet.waitForExistence(timeout: 5))
            let close = app.buttons["Close"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 3))
            close.tap()
            XCTAssertTrue(shareSheet.waitForNonExistence(timeout: 5))
        }
    }

    /// Signed out and never used by Claude: the badge says so, even though permissions default to on.
    func testClaudeBadgeDefaultsToNotConnected() {
        openSettings()
        let row = app.buttons["settings.claude"]
        scrollToHittable(row)
        let badge = app.staticTexts["settings.claude.badge"]
        let label = badge.exists ? badge.label : row.label
        XCTAssertTrue(label.contains("Not connected"), label)
    }

    /// Signed out, "Erase all data on this iPhone" wipes the local store and returns to onboarding.
    func testEraseAllDataReturnsToOnboarding() {
        openSettings()
        let erase = app.buttons["settings.delete"]
        scrollToHittable(erase)
        erase.tap()
        app.buttons["settings.delete.continue"].firstMatch.tap() // the dialog exposes it twice

        let field = app.textFields["settings.delete.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("DELETE")
        app.buttons["settings.delete.confirm"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["onboarding.welcome"].waitForExistence(timeout: 10))
    }
}
