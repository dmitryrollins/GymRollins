import XCTest

/// The add-equipment sheet from a gym's equipment screen. `-seedGym` gives "Home" with kettlebells and a flat bench;
/// `-gymPhotoFixture` makes Library use a generated picture. The simulator has no camera, so the buttons always show.
final class AddEquipmentUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        XCUIApplication.launchReady(["-seedGym", "-gymPhotoFixture"]) { $0.buttons["today.gymChip"] }
    }

    private func openAdd(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["today.gymChip"].tap()
        let current = app.buttons["gymPicker.currentEquipment"]
        XCTAssertTrue(current.waitForExistence(timeout: 5), file: file, line: line)
        current.tap()
        let add = app.buttons["gymEquipment.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), file: file, line: line)
        add.tap()
        XCTAssertTrue(app.buttons["addEquipment.skip"].waitForExistence(timeout: 5), "the photo step opens",
                      file: file, line: line)
    }

    /// Finds the kind by name, since the tile may be below the fold.
    private func chooseKind(_ app: XCUIApplication, _ id: String, search: String) {
        let field = app.textFields["addEquipment.kindSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText(search)
        app.buttons["addEquipment.kind.\(id)"].tapCenter()
    }

    private func save(_ app: XCUIApplication) {
        let save = app.buttons["addEquipment.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        for _ in 0..<5 where !save.isHittable { app.swipeUp() }
        save.tapCenter()
    }

    func testAddWithPhoto() {
        let app = launch()
        openAdd(app)
        app.buttons["addEquipment.library"].tap()
        chooseKind(app, "lat-pulldown", search: "lat")
        XCTAssertTrue(app.staticTexts["addEquipment.stackValue"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["addEquipment.stackValue"].label, "250 lb (113.4 kg)")
        app.buttons["addEquipment.stackPlus"].tap()
        XCTAssertEqual(app.staticTexts["addEquipment.stackValue"].label, "255 lb (115.7 kg)")
        save(app)
        XCTAssertTrue(app.buttons["gymEquipment.listing.lat-pulldown"].waitForExistence(timeout: 10),
                      "the new tile shows once the sheet closes")
        XCTAssertEqual(app.staticTexts["gymEquipment.subtitle"].label, "3 items")
    }

    func testSkipPhoto() {
        let app = launch()
        openAdd(app)
        app.buttons["addEquipment.skip"].tap()
        chooseKind(app, "barbell", search: "barbell")
        XCTAssertFalse(app.buttons["addEquipment.stackPlus"].exists, "plates need no weight input")
        XCTAssertTrue(app.buttons["addEquipment.save"].isEnabled)
        save(app)
        XCTAssertTrue(app.buttons["gymEquipment.listing.barbell"].waitForExistence(timeout: 10))
    }

    func testDuplicateStepAppears() {
        let app = launch()
        openAdd(app)
        app.buttons["addEquipment.skip"].tap()
        chooseKind(app, "kettlebells", search: "kettle")
        XCTAssertTrue(app.buttons["addEquipment.different"].waitForExistence(timeout: 5), "Home already lists kettlebells")
        XCTAssertTrue(app.buttons["addEquipment.generic"].exists)
        let same = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'addEquipment.same.'")).firstMatch
        XCTAssertTrue(same.exists)
        same.tapCenter()
        XCTAssertTrue(app.buttons["gymEquipment.add"].waitForExistence(timeout: 5), "the sheet closes")
        XCTAssertEqual(app.staticTexts["gymEquipment.subtitle"].label, "2 items", "nothing new was added")
    }

    func testFixedSetChipsSaveAndShowOnTheScreen() {
        let app = launch()
        openAdd(app)
        app.buttons["addEquipment.skip"].tap()
        chooseKind(app, "kettlebells", search: "kettle")
        app.buttons["addEquipment.different"].tapCenter()
        let chip = app.buttons["addEquipment.weight.16"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["addEquipment.weight.20"].exists)
        XCTAssertFalse(app.buttons["addEquipment.save"].isEnabled, "a fixed set needs a weight")
        chip.tap()
        XCTAssertTrue(app.buttons["addEquipment.save"].isEnabled)
        save(app)
        XCTAssertTrue(app.buttons["gymEquipment.add"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["gymEquipment.subtitle"].label, "3 items")
        let tiles = app.buttons.matching(identifier: "gymEquipment.listing.kettlebells")
        XCTAssertEqual(tiles.count, 2)
        XCTAssertTrue((0..<tiles.count).contains { tiles.element(boundBy: $0).label.contains("35") },
                      "the new 16 kg (35 lb) bell shows on a tile")
    }

    func testCancelLeavesNothing() {
        let app = launch()
        openAdd(app)
        app.buttons["addEquipment.library"].tap()
        XCTAssertTrue(app.textFields["addEquipment.kindSearch"].waitForExistence(timeout: 30), "the photo was cleaned")
        app.buttons["addEquipment.cancel"].tap()
        XCTAssertTrue(app.buttons["gymEquipment.add"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["gymEquipment.subtitle"].label, "2 items")
    }
}
