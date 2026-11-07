import XCTest

/// The Claude screen's Use with Claude section (plan 25): the prompt shows three lines, Show all opens the rest, and
/// Copy prompt turns to "Copied".
@MainActor
final class ClaudePromptsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() { continueAfterFailure = false }

    private func openClaude() {
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
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

    func testShowAllThenCopyThePrompt() {
        app = XCUIApplication.launchReady()
        openClaude()
        let text = app.staticTexts["claude.coach.text"]
        let showAll = app.buttons["claude.coach.showAll"]
        scrollUpTo(showAll)
        let collapsed = text.frame.height
        showAll.tap()
        XCTAssertGreaterThan(text.frame.height, collapsed)
        scrollUpTo(showAll) // the longer text can push the button below the fold
        XCTAssertEqual(showAll.label, "Show less")

        let copy = app.buttons["claude.coach.copy"]
        scrollUpTo(copy)
        XCTAssertEqual(copy.label, "Copy prompt")
        copy.tap()
        XCTAssertEqual(copy.label, "Copied")
    }
}
