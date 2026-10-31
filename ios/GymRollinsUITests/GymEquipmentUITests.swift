import XCTest

/// A gym's equipment screen, reached from the picker. `-seedGym` gives "Home" with kettlebells and a flat bench.
final class GymEquipmentUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = ["-seedGym"]) -> XCUIApplication {
        XCUIApplication.launchReady(extra) { $0.buttons["today.gymChip"] }
    }

    private func openEquipment(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["today.gymChip"].tap()
        let current = app.buttons["gymPicker.currentEquipment"]
        XCTAssertTrue(current.waitForExistence(timeout: 5), "picker didn't open", file: file, line: line)
        current.tap()
        XCTAssertTrue(app.buttons["gymEquipment.add"].waitForExistence(timeout: 5), "equipment didn't open",
                      file: file, line: line)
    }

    private func goBack(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    func testShowsHeaderCoverageAndTiles() {
        let app = launch()
        openEquipment(app)
        XCTAssertEqual(app.staticTexts["gymEquipment.title"].label, "Home")
        XCTAssertEqual(app.staticTexts["gymEquipment.subtitle"].label, "2 items")
        XCTAssertTrue(app.buttons["gymEquipment.listing.kettlebells"].exists)
        XCTAssertTrue(app.buttons["gymEquipment.listing.flat-bench"].exists)
        XCTAssertTrue(app.staticTexts["gymEquipment.coverage.chest"].waitForExistence(timeout: 10),
                      "coverage appears once counted")
        XCTAssertTrue(app.staticTexts["gymEquipment.coverage.legs"].exists)
        XCTAssertFalse(app.staticTexts["gymEquipment.empty"].exists)
    }

    func testAnEmptyGymSaysSo() {
        let app = launch([])
        app.buttons["today.gymChip"].tap()
        app.buttons["gymPicker.addPrivate"].tap()
        let name = app.textFields["privateGym.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Garage")
        app.buttons["privateGym.save"].tap()
        app.buttons["gymPicker.gym.Garage"].tap()
        XCTAssertTrue(app.buttons["gymPicker.close"].waitForNonExistence(timeout: 5))
        openEquipment(app)
        XCTAssertTrue(app.staticTexts["gymEquipment.empty"].exists)
        XCTAssertEqual(app.staticTexts["Nothing here yet. Add the first piece of equipment."].exists, true)
    }

    func testEditingLoadsSavesThemOnTheTile() {
        let app = launch()
        openEquipment(app)
        app.buttons["gymEquipment.listing.kettlebells"].tap()
        let chip = app.buttons["listing.weight.16"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        let save = app.buttons["listing.save"]
        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        save.tapCenter()
        let tile = app.buttons["gymEquipment.listing.kettlebells"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "Save returns to the equipment screen")
        XCTAssertTrue(tile.label.contains("35"), "the new 16 kg bell shows on the tile: \(tile.label)")
    }

    func testSavingNeedsAWeightForAFixedSet() {
        let app = launch()
        openEquipment(app)
        app.buttons["gymEquipment.listing.kettlebells"].tap()
        XCTAssertTrue(app.buttons["listing.weight.20"].waitForExistence(timeout: 5))
        app.buttons["listing.weight.20"].tap()
        app.buttons["listing.weight.24"].tap()
        XCTAssertFalse(app.buttons["listing.save"].isEnabled)
        app.buttons["listing.weight.24"].tap()
        XCTAssertTrue(app.buttons["listing.save"].isEnabled)
    }

    func testDeleteAsksFirstAndRemovesTheTile() {
        let app = launch()
        openEquipment(app)
        app.buttons["gymEquipment.listing.flat-bench"].tap()
        // A phone-only listing at a private gym also offers Sync, which pushes Delete down.
        func reveal(_ id: String) -> XCUIElement {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "missing \(id)")
            for _ in 0..<3 where !button.isHittable { app.swipeUp() }
            return button
        }
        reveal("listing.delete").tap()
        let cancel = reveal("listing.delete.cancel")
        cancel.tap()
        XCTAssertTrue(app.buttons["listing.delete"].waitForExistence(timeout: 5), "Cancel keeps it")
        reveal("listing.delete").tap()
        reveal("listing.delete.confirm").tap()
        XCTAssertTrue(app.buttons["gymEquipment.add"].waitForExistence(timeout: 5), "back on the equipment screen")
        XCTAssertTrue(app.buttons["gymEquipment.listing.flat-bench"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["gymEquipment.subtitle"].label, "1 item")
        XCTAssertTrue(app.buttons["gymEquipment.listing.kettlebells"].exists)
    }

    func testAddAPhotoToAListingWithNone() {
        let app = launch(["-seedGym", "-gymPhotoFixture"])
        openEquipment(app)
        app.buttons["gymEquipment.listing.flat-bench"].tap()
        let add = app.buttons["listing.addPhoto"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(add.waitForNonExistence(timeout: 30), "the photo was cleaned and attached")
        XCTAssertTrue(app.descendants(matching: .any)["listing.addPhoto.processing"].waitForNonExistence(timeout: 30),
                      "the photo finished processing")
        XCTAssertFalse(app.staticTexts["listing.error"].exists)
        // The tile can disappear while processing, or when the attach fails and the error shows: reopen to be sure.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["gymEquipment.listing.flat-bench"].waitForExistence(timeout: 5))
        app.buttons["gymEquipment.listing.flat-bench"].tap()
        XCTAssertTrue(app.buttons["listing.save"].waitForExistence(timeout: 5), "the listing reopened")
        XCTAssertFalse(app.buttons["listing.addPhoto"].exists, "the photo was saved: there is nothing left to add")
    }
}
