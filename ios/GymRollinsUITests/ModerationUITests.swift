import XCTest

/// The admin list, against the fake catalogue's three flagged items (`-fakeGymAdmin`).
final class ModerationUITests: XCTestCase {
    private let pulldown = "00000000-0000-4000-8000-0000000000D1"
    private let cable = "00000000-0000-4000-8000-0000000000D2"
    private let gym = "00000000-0000-4000-8000-0000000000D3"
    private let stale = "00000000-0000-4000-8000-0000000000D4"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        XCUIApplication.launchReady(["-fakeGymCatalog", "-fakeSignedIn"] + extra) { $0.tabBars.firstMatch }
    }

    private func openSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.buttons["log.settings"].waitForExistence(timeout: 5))
        app.buttons["log.settings"].tap()
    }

    func testRestoreAndRemoveEmptyTheList() {
        let app = launch(["-fakeGymAdmin"])
        openSettings(app)
        let row = app.buttons["settings.moderation"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "an admin sees the row")
        row.tap()
        XCTAssertTrue(app.buttons["moderation.restore.\(pulldown)"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Life Fitness Pulldown"].exists)
        XCTAssertTrue(app.staticTexts["Person in the photo x2"].exists)
        XCTAssertEqual(app.staticTexts["moderation.status.\(pulldown)"].label, "Hidden, 3 reports")
        XCTAssertEqual(app.staticTexts["moderation.status.\(cable)"].label, "1 report", "one report hides nothing")
        XCTAssertTrue(app.staticTexts["14 Side Street"].exists, "a gym shows its address")
        XCTAssertTrue(app.staticTexts["Iron Works, 1 Barbell Way"].exists, "a listing says which gym it is at")
        XCTAssertTrue(app.staticTexts["Notes: Bring your own towel"].exists, "a listing shows its own notes")
        XCTAssertEqual(app.staticTexts["moderation.status.\(stale)"].label, "Photo still to delete")
        XCTAssertFalse(app.buttons["moderation.restore.\(stale)"].exists, "a removed row can only be removed again")

        app.buttons["moderation.restore.\(pulldown)"].tap()
        XCTAssertTrue(app.buttons["moderation.restore.\(pulldown)"].waitForNonExistence(timeout: 5))

        app.buttons["moderation.remove.\(cable)"].tap()
        XCTAssertTrue(app.buttons["moderation.removeConfirm.\(cable)"].waitForExistence(timeout: 5), "asks first")
        app.buttons["moderation.removeCancel.\(cable)"].tap()
        XCTAssertTrue(app.buttons["moderation.remove.\(cable)"].waitForExistence(timeout: 5), "cancel keeps the row")
        app.buttons["moderation.remove.\(cable)"].tap()
        app.buttons["moderation.removeConfirm.\(cable)"].tap()
        XCTAssertTrue(app.buttons["moderation.remove.\(cable)"].waitForNonExistence(timeout: 5))

        app.buttons["moderation.remove.\(gym)"].tap()
        app.buttons["moderation.removeConfirm.\(gym)"].tap()
        XCTAssertTrue(app.buttons["moderation.remove.\(gym)"].waitForNonExistence(timeout: 5))

        app.buttons["moderation.remove.\(stale)"].tap() // finishing the job needs no second question
        XCTAssertTrue(app.descendants(matching: .any)["moderation.empty"].waitForExistence(timeout: 5))
    }

    func testAnAccountThatIsNotAnAdminHasNoModerationRow() {
        let app = launch([])
        openSettings(app)
        XCTAssertTrue(app.buttons["settings.claude"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["settings.moderation"].waitForExistence(timeout: 2))
    }
}
