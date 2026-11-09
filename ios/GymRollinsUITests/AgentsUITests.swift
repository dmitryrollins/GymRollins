import XCTest

/// Settings › AI agents, hermetic (plan 32). `-fakeAgents` lists Muse (agent.meta.ai, last used 2 h before the fixed
/// now) above Claude (claude.ai, never used) from memory; `-seedProposal` adds a pending proposal from Claude, and
/// `-seedAgentWorkout` a workout Muse added on Tuesday 22 Sep.
@MainActor
final class AgentsUITests: XCTestCase {
    private var app: XCUIApplication!
    private let muse = "MuseFakeClientId"
    private let claude = "ClaudeFakeClientId"

    override func setUp() { continueAfterFailure = false }

    private func openAgents(_ extra: [String]) {
        app = XCUIApplication.launchReady(extra)
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.claude"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        scrollTo(row)
        XCTAssertTrue(row.label.contains("AI agents"), row.label)
        row.tap()
        XCTAssertTrue(app.navigationBars["AI agents"].waitForExistence(timeout: 5))
    }

    private func scrollTo(_ element: XCUIElement, maxSwipes: Int = 12) {
        for _ in 0..<maxSwipes where !element.isHittable { app.swipeUp() }
    }

    /// A label, whatever case the Form shows it in.
    private func text(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
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

    func testTheAgentsAreListedWithTheirHostAndLastUse() {
        openAgents(["-fakeAgents"])
        let museName = app.staticTexts["agents.name.\(muse)"]
        XCTAssertTrue(museName.waitForExistence(timeout: 5))
        XCTAssertEqual(museName.label, "Muse")
        XCTAssertEqual(app.staticTexts["agents.host.\(muse)"].label, "agent.meta.ai")
        XCTAssertEqual(app.staticTexts["agents.lastUsed.\(muse)"].label, "Last used 2 h ago")
        let claudeName = app.staticTexts["agents.name.\(claude)"]
        XCTAssertEqual(claudeName.label, "Claude")
        XCTAssertEqual(app.staticTexts["agents.host.\(claude)"].label, "claude.ai")
        XCTAssertEqual(app.staticTexts["agents.lastUsed.\(claude)"].label, "Not used yet")
        XCTAssertLessThan(museName.frame.minY, claudeName.frame.minY) // newest connection first
        XCTAssertFalse(app.staticTexts["claude.status"].exists) // the rows replace the status line
    }

    func testDisconnectAsksFirstThenCutsOnlyThatAgent() {
        openAgents(["-fakeAgents"])
        let disconnect = app.buttons["agents.disconnect.\(muse)"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        XCTAssertEqual(disconnect.label, "Disconnect Muse")
        disconnect.tap()
        XCTAssertTrue(app.staticTexts["Disconnect Muse? It loses access until you approve it again."]
            .waitForExistence(timeout: 5))
        app.buttons["agents.disconnect.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["agents.name.\(muse)"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["agents.name.\(claude)"].exists)

        app.buttons["agents.disconnect.\(claude)"].tap()
        app.buttons["agents.disconnect.confirm"].firstMatch.tap()
        let status = app.staticTexts["claude.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "No agents connected.")
    }

    func testAddWorkoutsIsOffUntilTurnedOnAndStaysOn() {
        openAgents([])
        let add = app.switches["agents.perm.logWorkouts"]
        scrollTo(add)
        XCTAssertTrue(add.isHittable)
        XCTAssertEqual(add.value as? String, "0")
        XCTAssertTrue(add.label.contains("Add workouts"), add.label)
        XCTAssertTrue(add.label.contains("Let agents add past workouts to your history"), add.label)
        flip(add)
        XCTAssertEqual(add.value as? String, "1")

        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["settings.claude"].tap()
        XCTAssertTrue(app.navigationBars["AI agents"].waitForExistence(timeout: 5))
        scrollTo(add)
        XCTAssertEqual(add.value as? String, "1")
    }

    func testTheSectionsAreWordedForAnyAgent() {
        openAgents(["-seedProposal"])
        XCTAssertTrue(text("Connected agents").waitForExistence(timeout: 5))
        let status = app.staticTexts["claude.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let none = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "No agents connected."),
                                             object: status)
        XCTAssertEqual(XCTWaiter().wait(for: [none], timeout: 5), .completed, status.label)
        XCTAssertTrue(text("Connect").exists)

        let proposals = text("Plan changes from your agents")
        scrollTo(proposals)
        XCTAssertTrue(proposals.exists)
        XCTAssertFalse(text("Plan changes from Claude").exists)

        let permissions = text("What agents can do")
        scrollTo(permissions)
        XCTAssertTrue(permissions.exists)
        XCTAssertFalse(text("What Claude can do").exists)
        let gymsNote = app.staticTexts["claude.gymsNote"]
        scrollTo(gymsNote)
        XCTAssertTrue(gymsNote.label.hasPrefix("Agents can read gyms"), gymsNote.label)

        let useWithClaude = text("Use with Claude")
        scrollTo(useWithClaude)
        XCTAssertTrue(useWithClaude.exists)

        let disconnectAll = app.buttons["claude.disconnect"]
        scrollTo(disconnectAll)
        XCTAssertEqual(disconnectAll.label, "Disconnect all")
        disconnectAll.tap()
        XCTAssertTrue(app.staticTexts["Disconnect every agent?"].waitForExistence(timeout: 5))
        app.buttons["claude.disconnect.confirm"].firstMatch.tap()
        let revoked = app.staticTexts["claude.disconnected"]
        XCTAssertTrue(revoked.waitForExistence(timeout: 5))
        XCTAssertTrue(revoked.label.hasPrefix("Every agent's access was revoked"), revoked.label)
    }

    func testProposalsSayWhoSentThem() {
        openAgents(["-seedProposal"])
        let row = app.buttons["claude.proposal.C1A0DE00-0000-4000-8000-000000000001"]
        scrollTo(row)
        XCTAssertTrue(row.isHittable)
        XCTAssertTrue(row.label.contains("From Claude"), row.label)
        row.tap()
        let from = app.staticTexts["proposal.from"]
        XCTAssertTrue(from.waitForExistence(timeout: 5))
        XCTAssertEqual(from.label, "From Claude")
        XCTAssertTrue(app.descendants(matching: .any)["proposal.review"].exists)
    }

    /// The workout Muse added says so, and still does after the owner edits it (the edit is saved and read back).
    func testAWorkoutAnAgentAddedSaysWhoAndKeepsItThroughAnEdit() {
        app = XCUIApplication.launchReady(["-seedAgentWorkout"])
        app.tabBars.buttons["Log"].tap()
        let card = app.descendants(matching: .any)["log.workout.AD0ED000-0000-4000-8000-000000000001"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        let added = app.staticTexts["detail.addedBy"]
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        XCTAssertEqual(added.label, "Added by Muse")

        app.buttons["detail.menu"].tap()
        XCTAssertTrue(app.buttons["detail.edit"].waitForExistence(timeout: 5))
        app.buttons["detail.edit"].tap()
        let reps = app.textFields["detail.set.0.0.reps"]
        XCTAssertTrue(reps.waitForExistence(timeout: 5))
        reps.clearAndType("9")
        app.dismissKeyboardIfPresent()
        app.buttons["detail.save"].tap()
        let edited = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "1 9 \u{00D7}")).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 5))

        app.buttons["detail.back"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        XCTAssertEqual(added.label, "Added by Muse")
        XCTAssertTrue(edited.waitForExistence(timeout: 5)) // the edit was saved, and read back with the name
    }

    func testTheOwnersWorkoutsSayNothing() {
        app = XCUIApplication.launchReady(["-seedHistory"])
        app.tabBars.buttons["Log"].tap()
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        cards.firstMatch.tap()
        XCTAssertTrue(app.buttons["detail.menu"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["detail.addedBy"].exists)
    }
}
