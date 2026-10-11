import XCTest

final class LogUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-seedHistory", "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launch()
        return app
    }

    func testLogShowsSeededWorkoutsWithDuration() {
        let app = launch()
        app.tabBars.buttons["Log"].tap()
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(cards.count, 2)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '58:20'")).firstMatch
            .waitForExistence(timeout: 5))
    }

    func testDeleteWorkout() {
        let app = launch()
        app.tabBars.buttons["Log"].tap()
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        let before = cards.count
        cards.firstMatch.tap()

        XCTAssertTrue(app.buttons["detail.menu"].waitForExistence(timeout: 5))
        app.buttons["detail.menu"].tap()
        XCTAssertTrue(app.buttons["detail.delete"].waitForExistence(timeout: 5))
        app.buttons["detail.delete"].tap()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5))
        app.buttons["Delete"].tap()

        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(cards.count, before - 1)
    }

    func testEditWorkoutSet() {
        let app = launch()
        app.tabBars.buttons["Log"].tap()
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        cards.firstMatch.tap()

        XCTAssertTrue(app.buttons["detail.menu"].waitForExistence(timeout: 5))
        app.buttons["detail.menu"].tap()
        XCTAssertTrue(app.buttons["detail.edit"].waitForExistence(timeout: 5))
        app.buttons["detail.edit"].tap()

        let repsField = app.textFields["detail.set.0.0.reps"]
        XCTAssertTrue(repsField.waitForExistence(timeout: 5))
        repsField.clearAndType("11")
        app.dismissKeyboardIfPresent()

        app.buttons["detail.save"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '11 \u{00D7} 130 lb'")).firstMatch
            .waitForExistence(timeout: 5))
    }

    /// The seeded plank workout's exercise id has no library match, so `SetFieldFormat.mode`
    /// resolves `.time` from the sets' shape: detail editing should surface a "sec" field (not
    /// reps/weight) and save it back through the timed-set path.
    func testEditTimedSetDuration() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-seedPlank", "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launch()
        app.tabBars.buttons["Log"].tap()
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        cards.firstMatch.tap() // the plank workout is seeded most recent

        XCTAssertTrue(app.buttons["detail.menu"].waitForExistence(timeout: 5))
        app.buttons["detail.menu"].tap()
        XCTAssertTrue(app.buttons["detail.edit"].waitForExistence(timeout: 5))
        app.buttons["detail.edit"].tap()

        let secField = app.textFields["detail.set.0.0.sec"]
        XCTAssertTrue(secField.waitForExistence(timeout: 5))
        secField.clearAndType("20")
        app.dismissKeyboardIfPresent()

        app.buttons["detail.save"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '0:20'")).firstMatch
            .waitForExistence(timeout: 5))
    }

    /// With 60 seeded workouts (limit 50 fetched initially), a non-lazy stack would build every
    /// fetched card up front; `LazyVStack` should keep far fewer than the full 60 in the
    /// hierarchy until the user scrolls near the end, which fetches and reveals more.
    func testLogPaginatesLazilyOnScroll() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-seedLargeHistory", "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launch()
        app.tabBars.buttons["Log"].tap()

        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        let initialCount = cards.count
        XCTAssertLessThan(initialCount, 60)

        for _ in 0..<20 { app.swipeUp() }

        let grew = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in cards.count > initialCount }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [grew], timeout: 6), .completed)
    }
}
