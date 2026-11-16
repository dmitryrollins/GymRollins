import XCTest

/// A leg press's logged weight includes its sled: the plate calculator loads plates on the empty sled (100 lb until it
/// is changed in Bar & Plates), not on a 45 lb bar. Launched with `-emptyStore` (an lb profile, nothing logged).
final class SledPlatesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testLegPressPlatesGoOnTheSled() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipOnboarding", "-emptyStore", "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launch()

        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.buttons["log.empty.startWorkout"].waitForExistence(timeout: 5))
        app.buttons["log.empty.startWorkout"].tap()
        XCTAssertTrue(app.buttons["workout.addExercise"].waitForExistence(timeout: 5))
        app.buttons["workout.addExercise"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("sled 45")
        XCTAssertTrue(app.buttons["picker.row.0739"].waitForExistence(timeout: 5))
        app.buttons["picker.row.0739"].tap()
        app.navigationBars["Add Exercise"].buttons["Close"].tap()
        app.buttons["picker.add"].tap()
        XCTAssertTrue(app.buttons["workout.entry.0739"].waitForExistence(timeout: 3))
        app.buttons["workout.entry.0739"].tap()

        let weight = app.textFields["logging.set.0.weight"]
        XCTAssertTrue(weight.waitForExistence(timeout: 5))
        weight.clearAndType("225")
        app.dismissKeyboardIfPresent()
        XCTAssertTrue(app.staticTexts["Sled + Plates"].exists)

        // 225 lb on a 100 lb sled is 62.5 lb a side: 35 + 25 + 2.5 (on a 45 lb bar it would be two 45s).
        app.buttons["logging.chip.plates"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["plates.side.35"].waitForExistence(timeout: 3))
        for plate in ["25", "2.5"] {
            XCTAssertTrue(app.descendants(matching: .any)["plates.side.\(plate)"].exists, plate)
        }
        XCTAssertFalse(app.descendants(matching: .any)["plates.side.45"].exists)
        let sled = NSPredicate(format: "label ENDSWITH %@", "100 lb sled")
        XCTAssertTrue(app.staticTexts.matching(sled).firstMatch.exists)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "sled-plates"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
