import XCTest

/// Taps on Today and Library with an owner-sized history (160 workouts): every tap must open its screen. Attaches a
/// Library screenshot (the muscle badges, for comparing their look) and the tap-to-screen times it saw; the times
/// include XCUITest's own polling, so they compare runs rather than measure the app, and nothing asserts on them.
@MainActor
final class ResponsivenessUITests: XCTestCase {
    static let largeHistory = ["-seedLargeHistory", "-largeHistoryCount", "160"]

    private var timings: [String] = []

    override func setUp() { continueAfterFailure = false }

    override func tearDown() {
        let attachment = XCTAttachment(string: timings.joined(separator: "\n"))
        attachment.name = "tap-timings.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Taps `element`, waits for `opened`, and notes how long that took.
    private func tap(_ element: XCUIElement, opens opened: XCUIElement, _ name: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "missing \(name)")
        let start = Date()
        element.tap()
        XCTAssertTrue(opened.waitForExistence(timeout: 5), "\(name) didn't open")
        timings.append("TAP \(name): \(Int(Date().timeIntervalSince(start) * 1_000)) ms")
    }

    func testLibraryRowsOpenAndBadgesShow() {
        let app = XCUIApplication.launchReady(Self.largeHistory)
        app.tabBars.buttons["Library"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.row.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "library.png"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let title = app.staticTexts["detail.title"]
        // A row takes a tap anywhere, not only on its text or thumbnail: here on the empty right side of the second.
        let second = rows.element(boundBy: 1)
        XCTAssertTrue(second.isHittable)
        let start = Date()
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        let opened = title.waitForExistence(timeout: 5)
        timings.append("TAP Library row, right side: \(opened ? "\(Int(Date().timeIntervalSince(start) * 1_000)) ms" : "no response")")
        if opened { app.navigationBars.buttons.element(boundBy: 0).tap() }
        for round in 0..<3 {
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
            let row = rows.allElementsBoundByIndex.first { $0.isHittable && $0.frame.minY > 200 }
            guard let row else { return XCTFail("no hittable row") }
            tap(row, opens: title, "Library row after \(round) flings")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(opened, "a tap on a row's empty right side didn't open it")
    }

    func testTodayRowsOpen() {
        let app = XCUIApplication.launchReady(Self.largeHistory)
        let rows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'today.row.' AND NOT identifier BEGINSWITH 'today.row.menu.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let count = min(rows.count, 4)
        XCTAssertGreaterThan(count, 0)
        for index in 0..<count {
            tap(rows.element(boundBy: index), opens: app.staticTexts["logging.title"], "Today row \(index)")
            app.buttons["logging.close"].tap()
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        }
        tap(app.buttons["today.myPlan"], opens: app.navigationBars.buttons.element(boundBy: 0), "My Plan")
    }
}
