import XCTest

/// Claude's proposals, hermetic (no backend): `-seedProposal` inserts a pending proposal on the seeded plan with four
/// changes — Sun → Upper weak points, bench 140 → 145 lb, lever → dumbbell shoulder press on Pull, and leg extension
/// removed from Legs. 26 Sep 2026 is a Saturday, so Today shows Push + Arms (with the bench).
@MainActor
final class ProposalUITests: XCTestCase {
    static let fixedNow = "2026-09-26T09:00:00Z"
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-fixedNow", Self.fixedNow] + extra
        app.launch()
    }

    private var benchRow: XCUIElement { app.descendants(matching: .any)["today.row.0025"] }

    private func waitForBench(_ weight: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", weight)
        let match = expectation(for: predicate, evaluatedWith: benchRow)
        wait(for: [match], timeout: 5)
    }

    /// Flips a SwiftUI `Toggle` (the inner switch when there is one, else the right edge where the knob is).
    private func flip(_ toggle: XCUIElement) {
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let before = toggle.value as? String
        let inner = toggle.switches.firstMatch
        if inner.exists { inner.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let changed = NSPredicate(format: "value != %@", before ?? "")
        wait(for: [expectation(for: changed, evaluatedWith: toggle)], timeout: 3)
    }

    private func openReview() {
        let chip = app.buttons["today.proposal"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        XCTAssertTrue(app.descendants(matching: .any)["proposal.review"].waitForExistence(timeout: 5))
    }

    // MARK: Tests

    func testApplySubsetThenUndo() {
        launch(["-seedProposal"])
        waitForBench("140 lb")
        openReview()
        for id in ["c1", "c2", "c3", "c4"] {
            XCTAssertTrue(app.switches["proposal.change.\(id)"].exists, id)
        }
        XCTAssertEqual(app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'proposal.change.'")).count, 4)
        XCTAssertTrue(app.staticTexts["proposal.text.c2"].label.contains("140 lb \u{2192} 3 \u{00D7} 8\u{2013}10 @ 145 lb"),
                      app.staticTexts["proposal.text.c2"].label)

        flip(app.switches["proposal.change.c3"])
        let apply = app.buttons["proposal.apply"]
        XCTAssertEqual(apply.label, "Apply 3 changes")
        apply.tap()

        // Back on Today: the chip is gone and the bench plan is heavier.
        XCTAssertTrue(app.descendants(matching: .any)["proposal.toast"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["today.proposal"].exists)
        waitForBench("145 lb")

        app.buttons["proposal.undo"].tap()
        waitForBench("140 lb")
        XCTAssertTrue(app.descendants(matching: .any)["proposal.toast"].waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons["today.proposal"].exists) // undone proposals count as dismissed
    }

    /// `-seedTodayProposal`: Claude adds "Home · KB Upper" and picks it for today. Applying it switches Today to that
    /// routine (like Switch) — no need to use Switch — and the week's schedule keeps Push + Arms on Saturdays.
    func testTodayChangeSwitchesTodaysWorkout() {
        launch(["-seedTodayProposal"])
        let summary = app.staticTexts["today.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.hasPrefix("Push + Arms"), summary.label)
        openReview()
        let line = app.staticTexts["proposal.text.c4"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertEqual(line.label, "Today (Sat 26 Sep): Home \u{00B7} KB Upper instead of Push + Arms")
        let apply = app.buttons["proposal.apply"]
        XCTAssertEqual(apply.label, "Apply 4 changes")
        apply.tap()

        XCTAssertTrue(app.descendants(matching: .any)["proposal.toast"].waitForExistence(timeout: 5))
        let switched = NSPredicate(format: "label BEGINSWITH %@", "Home \u{00B7} KB Upper")
        wait(for: [expectation(for: switched, evaluatedWith: summary)], timeout: 5)
        XCTAssertTrue(app.descendants(matching: .any)["today.row.0520"].exists)

        // The routine was added, and the weekly schedule is untouched: Saturday doesn't become the home session.
        app.buttons["today.myPlan"].tap()
        XCTAssertTrue(app.buttons["plan.routine.Home \u{00B7} KB Upper"].waitForExistence(timeout: 5))
        let saturday = app.buttons["plan.day.6"]
        XCTAssertTrue(saturday.exists)
        XCTAssertFalse(saturday.label.contains("Home"), saturday.label)
    }

    func testDismissAllRemovesTheChip() {
        launch(["-seedProposal"])
        openReview()
        app.buttons["proposal.dismiss"].tap()
        XCTAssertTrue(app.buttons["today.proposal"].waitForNonExistence(timeout: 5))
        waitForBench("140 lb")
    }

    func testAutoApplyOnRelaunchAppliesTheProposal() {
        // 1. No proposal yet: turn on "Apply changes without asking" (saved on disk).
        launch(["-diskStore", "-resetStore"])
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let claude = app.buttons["settings.claude"]
        XCTAssertTrue(claude.waitForExistence(timeout: 5))
        claude.tap()
        let autoApply = app.switches["claude.perm.autoApply"]
        XCTAssertTrue(autoApply.waitForExistence(timeout: 5))
        XCTAssertEqual(autoApply.value as? String, "0")
        flip(autoApply)
        app.terminate()

        // 2. Relaunch with a proposal arriving: it's applied straight away, no chip.
        launch(["-diskStore", "-seedProposal"])
        waitForBench("145 lb")
        XCTAssertFalse(app.buttons["today.proposal"].exists)

        // Claude's screen offers to undo it.
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        app.buttons["settings.claude"].tap()
        let undo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'claude.undo.'")).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
    }

    func testClaudeScreenShowsConnectorPendingAndDisconnect() {
        launch(["-seedProposal"])
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        app.buttons["settings.claude"].tap()
        XCTAssertTrue(app.staticTexts["claude.status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["claude.url"].label.hasSuffix("/functions/v1/mcp"), app.staticTexts["claude.url"].label)
        app.buttons["claude.copyURL"].tap()
        XCTAssertEqual(app.buttons["claude.copyURL"].label, "Copied")
        XCTAssertTrue(app.buttons["claude.proposal.C1A0DE00-0000-4000-8000-000000000001"].exists)
        XCTAssertEqual(app.staticTexts["claude.status"].label, "Not connected yet")

        let disconnect = app.buttons["claude.disconnect"]
        scrollTo(disconnect)
        disconnect.tap()
        app.buttons["claude.disconnect.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["claude.disconnected"].waitForExistence(timeout: 5))
        for id in ["readWorkouts", "readBody", "readPlan", "propose", "autoApply"] {
            let toggle = app.switches["claude.perm.\(id)"]
            scrollTo(toggle)
            XCTAssertEqual(toggle.value as? String, "0", id)
        }
    }

    private func scrollTo(_ element: XCUIElement, maxSwipes: Int = 6) {
        var swipes = 0
        while !element.isHittable && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
    }
}
