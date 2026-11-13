import XCTest

/// Switch and Save Changes ask where a change goes (owner, 2026-11-10): this date only, or every week. The seed's today
/// is Saturday 26 Sep; Push + Arms is on Monday and Saturday, Pull on Wednesday.
final class TodayScopeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func summary(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["today.summary"].firstMatch }

    private func waitForSummary(_ app: XCUIApplication, containing text: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: summary(app))],
                                      timeout: 5)
        XCTAssertEqual(result, .completed, "summary was '\(summary(app).label)'", file: file, line: line)
    }

    private func onlyButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Only '")).firstMatch
    }

    /// Waits for the day's title between the swipes: two quick swipes once stayed on Sunday.
    private func waitForTitle(_ app: XCUIApplication, _ text: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let title = app.staticTexts["today.title"].firstMatch
        let predicate = NSPredicate(format: "label == %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: title)], timeout: 5)
        XCTAssertEqual(result, .completed, "title was '\(title.label)'", file: file, line: line)
    }

    private func openMonday(_ app: XCUIApplication) {
        app.scrollViews.firstMatch.swipeLeft()
        waitForTitle(app, "Tomorrow")
        app.scrollViews.firstMatch.swipeLeft()
        waitForTitle(app, "Monday")
        waitForSummary(app, containing: "Push + Arms")
    }

    private func mondayRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["today.backToToday"].tapCenter()
        app.buttons["today.myPlan"].tap()
        let monday = app.buttons["plan.day.1"]
        XCTAssertTrue(monday.waitForExistence(timeout: 5))
        return monday
    }

    func testSwitchingALaterDayOnlyChangesThatDate() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        openMonday(app)
        app.buttons["today.switch"].tap()
        let pull = app.buttons["today.switch.routine.Pull + Shoulders + Triceps"]
        XCTAssertTrue(pull.waitForExistence(timeout: 5))
        pull.tap()
        XCTAssertTrue(onlyButton(app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Every Monday"].exists)
        onlyButton(app).tap()
        waitForSummary(app, containing: "Pull + Shoulders + Triceps")
        waitForSummary(app, containing: "changed for this day")

        let monday = mondayRow(app)
        XCTAssertTrue(monday.label.contains("Push + Arms"), "the week is unchanged: \(monday.label)")
    }

    func testSwitchingEveryWeekChangesTheWeek() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        openMonday(app)
        app.buttons["today.switch"].tap()
        let pull = app.buttons["today.switch.routine.Pull + Shoulders + Triceps"]
        XCTAssertTrue(pull.waitForExistence(timeout: 5))
        pull.tap()
        let every = app.buttons["Every Monday"]
        XCTAssertTrue(every.waitForExistence(timeout: 5))
        every.tap()
        waitForSummary(app, containing: "Pull + Shoulders + Triceps")
        XCTAssertFalse(summary(app).label.contains("changed for this day"), summary(app).label)

        let monday = mondayRow(app)
        XCTAssertTrue(monday.label.contains("Pull"), monday.label)
    }

    func testSaveChangesOnlyThisDayMakesItsOwnCopy() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        app.buttons["today.row.menu.0025"].tap()
        let delete = app.buttons["Delete from Workout"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let save = app.buttons["today.saveToRoutine"]
        app.scrollToHittable(save)
        save.tap()
        let only = app.buttons["Only Saturday"]
        XCTAssertTrue(only.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Change Monday and Saturday"].exists)
        only.tap()
        waitForSummary(app, containing: "Push + Arms (Sat)")

        app.buttons["today.myPlan"].tap()
        let monday = app.buttons["plan.day.1"], saturday = app.buttons["plan.day.6"]
        XCTAssertTrue(monday.waitForExistence(timeout: 5))
        XCTAssertFalse(monday.label.contains("(Sat)"), monday.label)
        XCTAssertTrue(saturday.label.contains("Push + Arms (Sat)"), saturday.label)
    }

    /// Monday switched to Pull (on Wednesday only): Save Changes writes into Pull without asking, and Monday still trains
    /// Pull, without the deleted exercise.
    func testSaveChangesOnASwitchedLaterDayKeepsTheSwitch() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        openMonday(app)
        app.buttons["today.switch"].tap()
        let pull = app.buttons["today.switch.routine.Pull + Shoulders + Triceps"]
        XCTAssertTrue(pull.waitForExistence(timeout: 5))
        pull.tap()
        XCTAssertTrue(onlyButton(app).waitForExistence(timeout: 5))
        onlyButton(app).tap()
        waitForSummary(app, containing: "Pull + Shoulders + Triceps")
        let menu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'today.row.menu.'")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let exerciseId = String(menu.identifier.dropFirst("today.row.menu.".count))
        menu.tap()
        let delete = app.buttons["Delete from Workout"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let save = app.buttons["today.saveToRoutine"]
        app.scrollToHittable(save)
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5), "saved without a question")
        waitForSummary(app, containing: "Pull + Shoulders + Triceps")
        XCTAssertFalse(app.descendants(matching: .any)["today.row.\(exerciseId)"].exists)
    }
}
