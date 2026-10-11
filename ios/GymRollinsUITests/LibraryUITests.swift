import XCTest

final class LibraryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launch()
        app.tabBars.buttons["Library"].tap()
    }

    func testSearchAndOpenDetail() {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("barbell bench press")
        let row = app.buttons["library.row.0025"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detail.title"].label, "Barbell Bench Press")
        // The "Instructions" tab is a segmented-control segment, which XCUITest exposes as a
        // Button, not a StaticText (confirmed via an accessibility hierarchy dump).
        XCTAssertTrue(app.buttons["Instructions"].exists)
    }

    func testFilterByBodyPart() {
        app.buttons["library.filter.back"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("cable pulldown")
        XCTAssertTrue(app.buttons["library.row.0198"].waitForExistence(timeout: 5)) // cable pulldown
        XCTAssertFalse(app.buttons["library.row.0025"].exists) // barbell bench press: wrong body part
    }

    func testFilterByBodyPartReachesLastRowBySwiping() {
        // 1367 (wide grip rear pull-up) is the last "back" exercise in library order. With the
        // LazyVStack, it isn't in the accessibility tree until scrolled near, so swipe up to it.
        app.buttons["library.filter.back"].tap()
        let row = app.buttons["library.row.1367"]
        var swipes = 0
        while !row.isHittable && swipes < 60 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.isHittable)
    }

    func testCreateCustomExercise() {
        app.buttons["library.add"].tap()
        let name = app.textFields["custom.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Handle Band Squat to Press")
        app.buttons["custom.save"].tap()
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("handle band squat")
        XCTAssertTrue(app.staticTexts["Handle Band Squat To Press"].waitForExistence(timeout: 5))
    }
}
