import XCTest

/// The gym chip on Today and the picker it opens. Location and Maps are faked (`-fakeLocation`, `-fakeGymPlaces`),
/// so nothing here prompts for permission or reaches the network.
final class GymPickerUITests: XCTestCase {
    private let here = "40.0,-74.0"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        XCUIApplication.launchReady(extra) { $0.buttons["today.gymChip"] }
    }

    private func openPicker(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["today.gymChip"].tap()
        XCTAssertTrue(app.buttons["gymPicker.close"].waitForExistence(timeout: 5), "picker didn't open",
                      file: file, line: line)
    }

    func testPickerIsReachableAndCancelable() {
        let app = launch()
        XCTAssertEqual(app.buttons["today.gymChip"].label, "Gym: none")
        openPicker(app)
        XCTAssertTrue(app.buttons["gymPicker.addPrivate"].exists)
        XCTAssertTrue(app.buttons["gymPicker.none"].exists)
        app.buttons["gymPicker.close"].tap()
        XCTAssertTrue(app.buttons["gymPicker.close"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["today.gymChip"].label, "Gym: none")
    }

    func testAddAPrivateGymAndPickIt() {
        let app = launch()
        openPicker(app)
        app.buttons["gymPicker.addPrivate"].tap()
        let save = app.buttons["privateGym.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "a blank name can't be saved")
        let name = app.textFields["privateGym.name"]
        name.tap()
        name.typeText("Garage")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let row = app.buttons["gymPicker.gym.Garage"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the new gym is listed under My gyms")
        row.tap()
        XCTAssertTrue(app.buttons["gymPicker.close"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["today.gymChip"].label, "Gym: Garage")
    }

    func testPickAMapsGymWithFakePlaces() {
        let app = launch(["-fakeLocation", here, "-fakeGymPlaces"])
        openPicker(app)
        let search = app.textFields["gymPicker.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Iron")
        let place = app.buttons["gymPicker.place.fake-iron-works"]
        XCTAssertTrue(place.waitForExistence(timeout: 5), "search results appear after the debounce")
        place.tap()
        XCTAssertTrue(app.buttons["gymPicker.close"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["today.gymChip"].label, "Gym: Iron Works Gym")

        openPicker(app)
        XCTAssertTrue(app.buttons["gymPicker.gym.Iron Works Gym"].waitForExistence(timeout: 5),
                      "a picked Maps gym is kept under My gyms")
    }

    func testNearbySuggestionOffersTrainHere() {
        let app = launch(["-fakeLocation", here, "-fakeGymPlaces"])
        let suggestion = app.descendants(matching: .any)["today.gymSuggestion"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10), "Today suggests the gym you're at")
        XCTAssertEqual(app.buttons["today.gymChip"].label, "Gym: none", "a suggestion never switches by itself")
        app.buttons["today.gymSuggestion.accept"].tap()
        XCTAssertTrue(suggestion.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["today.gymChip"].label, "Gym: Iron Works Gym")

        openPicker(app)
        XCTAssertFalse(app.buttons["gymPicker.nearby.train"].exists, "the current gym isn't offered again")
    }

    func testNearbySuggestionCanBeDismissed() {
        let app = launch(["-fakeLocation", here, "-fakeGymPlaces"])
        let suggestion = app.descendants(matching: .any)["today.gymSuggestion"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
        app.buttons["today.gymSuggestion.dismiss"].tap()
        XCTAssertTrue(suggestion.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["today.gymChip"].label, "Gym: none")
    }

    func testPickerOffersTrainHereForANearbyGym() {
        let app = launch(["-fakeLocation", here, "-fakeGymPlaces"])
        openPicker(app)
        let train = app.buttons["gymPicker.nearby.train"]
        XCTAssertTrue(train.waitForExistence(timeout: 10))
        train.tap()
        XCTAssertTrue(app.buttons["gymPicker.close"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["today.gymChip"].label, "Gym: Iron Works Gym")
    }

    func testNoGymGoesBackToThePlainPlan() {
        let app = launch(["-seedGym"])
        XCTAssertEqual(app.buttons["today.gymChip"].label, "Gym: Home")
        openPicker(app)
        app.buttons["gymPicker.none"].tap()
        XCTAssertTrue(app.buttons["gymPicker.close"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["today.gymChip"].label, "Gym: none")
        XCTAssertTrue(app.staticTexts["today.summary"].exists)
    }

    func testDeletingAGymAsksFirstAndNamesTheItems() {
        let app = launch(["-seedGym"])
        openPicker(app)
        let row = app.buttons["gymPicker.gym.Home"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        app.buttons["Delete"].tap()
        let confirm = app.buttons["gymPicker.delete.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let message = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '2 items'")).firstMatch
        XCTAssertTrue(message.exists, "it says how many items go")
        confirm.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["today.gymChip"].label, "Gym: none", "deleting the current gym clears it")
    }
}
