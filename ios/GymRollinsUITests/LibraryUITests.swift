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

    /// The header like a contacts app (owner, 2026-11-19): the pill counts the exercises shown, following the
    /// body-part filter; Search swaps the pill for the field, and ✕ closes it and shows them all again.
    func testTheHeaderCountsAndOpensSearch() {
        let count = app.staticTexts["library.subtitle"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let all = count.label
        XCTAssertTrue(all.hasSuffix(" exercises"), all)
        app.buttons["library.filter.back"].tap()
        XCTAssertNotEqual(count.label, all, "the count follows the filter")
        app.buttons["library.filter.all"].tap()
        XCTAssertEqual(count.label, all)

        app.buttons["library.searchButton"].tap()
        let search = app.searchFields["library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["library.title"].exists, "the field takes the pill's place")
        search.typeText("barbell bench press") // the field has the keyboard
        XCTAssertTrue(app.buttons["library.row.0025"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "library-search"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["library.closeSearch"].tap()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, all, "closing clears the search")
        XCTAssertFalse(search.exists)
    }

    func testMusclesTabShowsTheBodyMap() {
        let search = app.librarySearch()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("barbell bench press")
        let row = app.buttons["library.row.0025"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
        app.buttons["Muscles"].tap()
        let map = app.otherElements["detail.muscleMap"]
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        XCTAssertTrue(map.label.localizedCaseInsensitiveContains("chest"), map.label)
    }

    func testSearchAndOpenDetail() {
        let search = app.librarySearch()
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
        let search = app.librarySearch()
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
        let search = app.librarySearch()
        search.tap()
        search.typeText("handle band squat")
        XCTAssertTrue(app.staticTexts["Handle Band Squat To Press"].waitForExistence(timeout: 5))
    }
}
