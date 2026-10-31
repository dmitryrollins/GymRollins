import XCTest

/// A listing with no photo of its own shows our stock photo of its kind, marked "Sample". `-uiTestingPhotos` gives
/// every kind a locally drawn stock photo except `skierg`, so both paths show. The simulator has no camera, so only
/// the Add a photo path can be driven here.
final class KindPhotoUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        XCUIApplication.launchReady(["-seedGym", "-uiTestingPhotos", "-gymPhotoFixture"]) { $0.buttons["today.gymChip"] }
    }

    private func openEquipment(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["today.gymChip"].tap()
        let current = app.buttons["gymPicker.currentEquipment"]
        XCTAssertTrue(current.waitForExistence(timeout: 5), "picker didn't open", file: file, line: line)
        current.tap()
        XCTAssertTrue(app.buttons["gymEquipment.add"].waitForExistence(timeout: 5), "equipment didn't open",
                      file: file, line: line)
    }

    /// The tile is one combined element, so the "Sample" capsule shows up in its label.
    private func tileLabelHasSample(_ tile: XCUIElement, _ expected: Bool, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS 'Sample'")
        if expected {
            return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: tile)], timeout: timeout) == .completed
        }
        return !predicate.evaluate(with: tile)
    }

    private func addSkiErg(_ app: XCUIApplication) {
        app.buttons["gymEquipment.add"].tap()
        XCTAssertTrue(app.buttons["addEquipment.skip"].waitForExistence(timeout: 5))
        app.buttons["addEquipment.skip"].tap()
        let field = app.textFields["addEquipment.kindSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText("ski")
        app.buttons["addEquipment.kind.skierg"].tapCenter()
        let save = app.buttons["addEquipment.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        for _ in 0..<5 where !save.isHittable { app.swipeUp() }
        save.tapCenter()
        XCTAssertTrue(app.buttons["gymEquipment.listing.skierg"].waitForExistence(timeout: 10))
    }

    func testAListingWithNoPhotoShowsTheSamplePhotoOnTheTileAndInDetail() {
        let app = launch()
        openEquipment(app)
        let tile = app.buttons["gymEquipment.listing.flat-bench"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertTrue(tileLabelHasSample(tile, true), "the tile reads Sample: \(tile.label)")
        tile.tap()
        XCTAssertTrue(app.staticTexts["listing.samplePhoto"].waitForExistence(timeout: 10), "the capsule shows")
        XCTAssertTrue(app.staticTexts["listing.samplePhotoNote"].exists, "the caption shows")
        XCTAssertTrue(app.buttons["listing.addPhoto"].exists, "the user can still add their own")
    }

    func testAKindWithNoStockPhotoShowsThePlaceholderAndTheAddPath() {
        let app = launch()
        openEquipment(app)
        addSkiErg(app)
        let tile = app.buttons["gymEquipment.listing.skierg"]
        XCTAssertTrue(tileLabelHasSample(tile, false), "no capsule on the tile: \(tile.label)")
        tile.tap()
        XCTAssertTrue(app.buttons["listing.addPhoto"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["listing.samplePhoto"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["listing.samplePhotoNote"].exists)
    }

    func testAddingAPhotoRemovesTheSampleMarksForGood() {
        let app = launch()
        openEquipment(app)
        app.buttons["gymEquipment.listing.flat-bench"].tap()
        XCTAssertTrue(app.staticTexts["listing.samplePhoto"].waitForExistence(timeout: 10))
        let add = app.buttons["listing.addPhoto"]
        add.tap()
        XCTAssertTrue(add.waitForNonExistence(timeout: 30), "the photo was cleaned and attached")
        XCTAssertTrue(app.staticTexts["listing.samplePhoto"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["listing.samplePhotoNote"].waitForNonExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        let tile = app.buttons["gymEquipment.listing.flat-bench"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertTrue(tileLabelHasSample(tile, false), "the tile shows their photo: \(tile.label)")
        tile.tap()
        XCTAssertTrue(app.buttons["listing.save"].waitForExistence(timeout: 5), "the listing reopened")
        XCTAssertFalse(app.staticTexts["listing.samplePhoto"].exists)
        XCTAssertFalse(app.staticTexts["listing.samplePhotoNote"].exists)
        XCTAssertFalse(app.buttons["listing.addPhoto"].exists)
    }
}
