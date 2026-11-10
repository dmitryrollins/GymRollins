import XCTest

/// Today shows later days read-only: swipe left for the next day, tap the date for a calendar, Back to today returns.
final class TodayDaysUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func title(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["today.title"].firstMatch }

    private func waitForLabel(_ element: XCUIElement, _ text: String, contains: Bool = false,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: contains ? "label CONTAINS %@" : "label == %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5)
        XCTAssertEqual(result, .completed, "label was '\(element.label)'", file: file, line: line)
    }

    func testSwipingShowsLaterDaysAndBackToTodayReturns() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        waitForLabel(title(app), "Today")
        app.scrollViews.firstMatch.swipeLeft()
        waitForLabel(title(app), "Tomorrow")
        waitForLabel(app.staticTexts["today.summary"].firstMatch, "Rest day", contains: true)
        XCTAssertFalse(app.buttons["today.start"].exists, "a later day can't be started")
        XCTAssertFalse(app.buttons["today.switch"].exists)

        app.scrollViews.firstMatch.swipeLeft()
        waitForLabel(title(app), "Monday")
        waitForLabel(app.staticTexts["today.summary"].firstMatch, "Push + Arms", contains: true)

        app.scrollViews.firstMatch.swipeRight()
        waitForLabel(title(app), "Tomorrow")
        app.buttons["today.backToToday"].tapCenter()
        waitForLabel(title(app), "Today")
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))

        app.scrollViews.firstMatch.swipeRight()
        waitForLabel(title(app), "Today") // nothing before today
    }

    func testTheCalendarPicksADayAndTodayComesBack() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        app.buttons["today.date"].tap()
        let picker = app.datePickers["today.datePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        // The graphical picker's day buttons are labelled like "Wednesday 30 September"; match on the day and month.
        let wednesday = picker.buttons.matching(NSPredicate(format: "label CONTAINS '30' AND label CONTAINS 'September'"))
            .firstMatch
        XCTAssertTrue(wednesday.waitForExistence(timeout: 5))
        wednesday.tap()
        waitForLabel(title(app), "Wednesday")
        waitForLabel(app.staticTexts["today.summary"].firstMatch, "Pull", contains: true)

        app.buttons["today.date"].tap()
        app.buttons["today.datePicker.today"].tap()
        waitForLabel(title(app), "Today")
    }
}
