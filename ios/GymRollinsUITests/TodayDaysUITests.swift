import XCTest

/// Today's later days (owner, 2026-11-10): swipe left for the next day, tap the date for a calendar, Back to today
/// returns. A later day is changed for that date only.
final class TodayDaysUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Waits for the day shown: the workout pill's value ("Today", "Tomorrow", "Monday").
    private func waitForDay(_ app: XCUIApplication, _ day: String, file: StaticString = #filePath, line: UInt = #line) {
        let pill = app.descendants(matching: .any)["today.workout"].firstMatch
        let predicate = NSPredicate(format: "value == %@", day)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: pill)], timeout: 5)
        XCTAssertEqual(result, .completed, "day was '\(pill.value ?? "")'", file: file, line: line)
    }

    private func waitForLabel(_ element: XCUIElement, _ text: String, contains: Bool = false,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: contains ? "label CONTAINS %@" : "label == %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5)
        XCTAssertEqual(result, .completed, "label was '\(element.label)'", file: file, line: line)
    }

    func testSwipingShowsLaterDaysAndBackToTodayReturns() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        waitForDay(app, "Today")
        app.scrollViews.firstMatch.swipeLeft()
        waitForDay(app, "Tomorrow")
        waitForLabel(app.descendants(matching: .any)["today.workout"].firstMatch, "Rest day", contains: true)
        XCTAssertFalse(app.buttons["today.start"].exists, "a later day can't be started")
        XCTAssertTrue(app.buttons["today.workout"].exists, "a later day can be switched")

        app.scrollViews.firstMatch.swipeLeft()
        waitForDay(app, "Monday")
        waitForLabel(app.descendants(matching: .any)["today.workout"].firstMatch, "Push + Arms", contains: true)

        app.scrollViews.firstMatch.swipeRight()
        waitForDay(app, "Tomorrow")
        app.buttons["today.backToToday"].tapCenter()
        waitForDay(app, "Today")
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))

        app.scrollViews.firstMatch.swipeRight()
        waitForDay(app, "Today") // nothing before today
    }

    func testTheCalendarPicksADayAndTodayComesBack() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        app.buttons["today.date"].tap()
        let picker = app.descendants(matching: .any)["today.datePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        // The calendar's day buttons are labelled like "Wednesday 30 September"; match on the day and month.
        let wednesday = picker.buttons.matching(NSPredicate(format: "label CONTAINS '30' AND label CONTAINS 'September'"))
            .firstMatch
        XCTAssertTrue(wednesday.waitForExistence(timeout: 5))
        wednesday.tap()
        waitForDay(app, "Wednesday")
        waitForLabel(app.descendants(matching: .any)["today.workout"].firstMatch, "Pull", contains: true)

        app.buttons["today.date"].tap()
        app.buttons["today.datePicker.today"].tap()
        waitForDay(app, "Today")
    }

    /// The calendar counts the month it shows (owner, 2026-11-19): the seed's September workouts are done, Monday 28 and
    /// Wednesday 30 are planned (today too, unless it's done) and Sunday 27 and Tuesday 29 are still empty; October
    /// plans its 18 training days.
    func testTheCalendarCountsTheMonthShown() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.buttons["today.date"].tap()
        let empty = app.descendants(matching: .any)["today.calendar.empty"]
        let planned = app.descendants(matching: .any)["today.calendar.planned"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "calendar-september"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertEqual(empty.value as? String, "2 days")
        let done = app.descendants(matching: .any)["today.calendar.done"]
        XCTAssertNotEqual(done.value as? String, "0 days", "the seed's September workouts")
        XCTAssertTrue(["2 days", "3 days"].contains(planned.value as? String ?? ""), "\(planned.value ?? "")")

        app.buttons["Next Month"].tap()
        let october = NSPredicate(format: "value == '18 days'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: october, object: planned)],
                                        timeout: 5), .completed, "\(planned.value ?? "")")
        XCTAssertEqual(empty.value as? String, "13 days")
    }

    /// Monday loses Bench Press for that date only: today keeps it, Monday says so, and Reset this day brings it back.
    func testALaterDayIsChangedForThatDateOnly() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        app.scrollViews.firstMatch.swipeLeft()
        waitForDay(app, "Tomorrow")
        app.scrollViews.firstMatch.swipeLeft()
        waitForDay(app, "Monday")
        XCTAssertFalse(app.buttons["today.start"].exists, "a later day can't be started")
        let bench = app.descendants(matching: .any)["today.row.0025"]
        XCTAssertTrue(bench.waitForExistence(timeout: 5))
        app.buttons["today.row.menu.0025"].tap()
        let delete = app.buttons["Delete from Workout"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(bench.waitForNonExistence(timeout: 5))
        waitForLabel(app.descendants(matching: .any)["today.workout"].firstMatch, "changed for this day", contains: true)

        app.buttons["today.backToToday"].tapCenter()
        waitForDay(app, "Today")
        XCTAssertTrue(bench.waitForExistence(timeout: 5), "today's Push + Arms still has it")

        app.scrollViews.firstMatch.swipeLeft()
        waitForDay(app, "Tomorrow")
        app.scrollViews.firstMatch.swipeLeft()
        waitForDay(app, "Monday")
        XCTAssertFalse(bench.exists, "Monday kept its change")
        let reset = app.buttons["today.resetDay"]
        app.scrollToHittable(reset)
        // Clear of the floating Back to today bar, which a short day can leave over it (the header no longer scrolls).
        if reset.frame.maxY > app.buttons["today.backToToday"].frame.minY { app.swipeUp() }
        reset.tap()
        XCTAssertTrue(bench.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["today.workout"].firstMatch.label.contains("changed"))
    }
}
