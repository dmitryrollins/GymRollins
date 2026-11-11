import XCTest

/// Today's later days (owner, 2026-11-10): swipe left for the next day, tap the date for a calendar, Back to today
/// returns. A later day is changed for that date only.
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
        XCTAssertTrue(app.buttons["today.switch"].exists, "a later day can be switched")

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

    /// Monday loses Bench Press for that date only: today keeps it, Monday says so, and Reset this day brings it back.
    func testALaterDayIsChangedForThatDateOnly() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        app.scrollViews.firstMatch.swipeLeft()
        app.scrollViews.firstMatch.swipeLeft()
        waitForLabel(title(app), "Monday")
        XCTAssertFalse(app.buttons["today.start"].exists, "a later day can't be started")
        let bench = app.descendants(matching: .any)["today.row.0025"]
        XCTAssertTrue(bench.waitForExistence(timeout: 5))
        app.buttons["today.row.menu.0025"].tap()
        let delete = app.buttons["Delete from Workout"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(bench.waitForNonExistence(timeout: 5))
        waitForLabel(app.staticTexts["today.summary"].firstMatch, "changed for this day", contains: true)

        app.buttons["today.backToToday"].tapCenter()
        waitForLabel(title(app), "Today")
        XCTAssertTrue(bench.waitForExistence(timeout: 5), "today's Push + Arms still has it")

        app.scrollViews.firstMatch.swipeLeft()
        app.scrollViews.firstMatch.swipeLeft()
        waitForLabel(title(app), "Monday")
        XCTAssertFalse(bench.exists, "Monday kept its change")
        let reset = app.buttons["today.resetDay"]
        app.scrollToHittable(reset)
        reset.tap()
        XCTAssertTrue(bench.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["today.summary"].firstMatch.label.contains("changed"))
    }
}
