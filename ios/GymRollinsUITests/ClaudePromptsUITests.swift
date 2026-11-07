import XCTest

/// The Claude screen's Use with Claude and Ready requests sections (plan 25): Show all, Copy marking only the last
/// copied row, and the weight request following Settings › Units. The seeded owner trains in lb.
@MainActor
final class ClaudePromptsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() { continueAfterFailure = false }

    private func openSettings() {
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
    }

    private func openClaude() {
        let row = app.buttons["settings.claude"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.staticTexts["claude.status"].waitForExistence(timeout: 5))
    }

    private func scrollUpTo(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<12 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, "\(element)", file: file, line: line)
    }

    func testCopyMarksOnlyTheLastCopiedRow() {
        app = XCUIApplication.launchReady()
        openSettings()
        openClaude()
        let text = app.staticTexts["claude.coach.text"]
        let showAll = app.buttons["claude.coach.showAll"]
        scrollUpTo(showAll)
        let collapsed = text.frame.height
        showAll.tap()
        XCTAssertEqual(showAll.label, "Show less")
        XCTAssertGreaterThan(text.frame.height, collapsed)

        let coach = app.buttons["claude.coach.copy"]
        scrollUpTo(coach)
        XCTAssertEqual(coach.label, "Copy coach prompt")
        coach.tap()
        XCTAssertEqual(coach.label, "Copied")

        let tomorrow = app.buttons["claude.request.tomorrow"]
        scrollUpTo(tomorrow)
        XCTAssertEqual(tomorrow.label, "Plan my workout for tomorrow.")
        tomorrow.tap()
        XCTAssertEqual(tomorrow.value as? String, "Copied")
        for _ in 0..<12 where !coach.isHittable { app.swipeDown() }
        XCTAssertEqual(coach.label, "Copy coach prompt")
    }

    func testTheWeightRequestFollowsTheUnit() {
        app = XCUIApplication.launchReady()
        openSettings()
        openClaude()
        let weight = app.buttons["claude.request.weight"]
        scrollUpTo(weight)
        XCTAssertEqual(weight.label, "Log my weight today: __ lb")

        app.navigationBars.buttons.firstMatch.tap() // back to Settings; Units is above the Claude row
        let units = app.buttons["settings.units"]
        for _ in 0..<6 where !units.isHittable { app.swipeDown() }
        units.tap()
        app.buttons["kg plates"].tap()
        openClaude()
        scrollUpTo(weight)
        XCTAssertEqual(weight.label, "Log my weight today: __ kg")
    }
}
