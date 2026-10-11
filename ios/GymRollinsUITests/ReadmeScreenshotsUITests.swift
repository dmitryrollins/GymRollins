import XCTest

/// Captures the screenshots used in the public README, from the app's DEBUG mock-data seeds (nothing real is read).
/// Skipped unless `README_SCREENSHOTS_DIR` is set, so the normal suite is unaffected. Regenerate with
/// `scripts/readme-screenshots.sh` (full-size PNGs go to `$README_SCREENSHOTS_DIR`, README-sized copies to
/// `docs/readme/`), or by hand:
/// `TEST_RUNNER_README_SCREENSHOTS_DIR=/some/dir xcodebuild test … -only-testing:GymRollinsUITests/ReadmeScreenshotsUITests`.
///
/// Every test launches the app fresh at the same fixed Saturday morning, so the dates, streaks and recovery map
/// are stable from run to run. Files: `01-today`, `02-workout`, `03-claude-proposal`, `04-body` (weekly sets),
/// `04b-recovery-map`, `04c-body-weight`, `05-log`, `06-claude-connect`.
@MainActor
final class ReadmeScreenshotsUITests: XCTestCase {
    /// Where the full-size PNGs go (`TEST_RUNNER_README_SCREENSHOTS_DIR` reaches the runner as this variable).
    nonisolated private static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["README_SCREENSHOTS_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard Self.outputDirectory != nil else {
            throw XCTSkip("README_SCREENSHOTS_DIR isn't set; this test only runs from scripts/readme-screenshots.sh")
        }
    }

    // MARK: Helpers

    /// Six weeks of the split (recovery map, weekly sets, streak, past workouts) plus five weekly weigh-ins for the
    /// bodyweight chart: the fullest Today, Body and Log the seeds give.
    private static let fullHistory = ["-seedInsights", "-seedBodyweight"]

    /// Launches on Today (waiting for its Start Workout button) with `-uiTesting`, the fixed date and `extra` seeds.
    private func launch(_ extra: [String], environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-fixedNow", XCUIApplication.fixedNow] + extra
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launchReady(firstElement: app.buttons["today.start"])
        return app
    }

    /// Writes a full-resolution PNG of the whole screen (status bar included) and attaches it to the result bundle.
    private func capture(_ name: String) throws {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = try XCTUnwrap(Self.outputDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try shot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// Lets SwiftUI animations (sheet presentation, list insertions, chart drawing) finish before the capture.
    private func settle(_ seconds: TimeInterval = 1.2) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Scrolls `scroller` up until `target` exists and is hittable (lazy List/Form rows).
    private func scroll(_ scroller: XCUIElement, to target: XCUIElement, attempts: Int = 10) {
        for _ in 0..<attempts where !(target.exists && target.isHittable) { scroller.swipeUp() }
        XCTAssertTrue(target.waitForExistence(timeout: 3), "never scrolled to \(target)")
    }

    /// Drags the page by `points` (positive scrolls further down). A slow drag that holds at the end scrolls the page
    /// 1:1 with no flick momentum, less the ~10 pt the touch has to travel before the scroll view takes over.
    private func nudge(_ app: XCUIApplication, by points: CGFloat) {
        let touchSlop: CGFloat = 10
        let travel = points + (points < 0 ? -touchSlop : touchSlop)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -travel)),
                    withVelocity: .slow, thenHoldForDuration: 0.5)
        settle(0.8)
    }

    /// Scrolls so `target`'s top edge sits `y` points from the top of the screen (within a few points). It
    /// overshoots by `overshoot` and scrolls back before the final correction.
    private func position(_ app: XCUIApplication, _ target: XCUIElement, atY y: CGFloat, overshoot: CGFloat = 150) {
        settle() // a flick from `scroll(_:to:)` may still be coasting
        nudge(app, by: target.frame.minY - (y - overshoot))
        nudge(app, by: -overshoot)
        for _ in 0..<2 where abs(target.frame.minY - y) > 4 { nudge(app, by: target.frame.minY - y) }
        XCTAssertEqual(target.frame.minY, y, accuracy: 6, "couldn't position \(target)")
    }

    // MARK: Screens

    func test01Today() throws {
        let app = launch(Self.fullHistory)
        XCTAssertTrue(app.buttons["today.row.0025"].waitForExistence(timeout: 10))
        settle()
        try capture("01-today")
    }

    func test02Workout() throws {
        let app = launch(["-seedHistory", "-workoutStartedMinutesAgo", "24"])
        app.startWorkout()
        app.openExercise("0025")
        app.buttons["logging.logSet"].tapCenter() // warm-up 1
        app.buttons["logging.rest.skip"].tap()
        app.buttons["logging.logSet"].tapCenter() // warm-up 2
        app.buttons["logging.rest.skip"].tap()
        app.buttons["logging.logSet"].tapCenter() // working set 1 -> rest timer runs
        XCTAssertTrue(element(app, "logging.rest").waitForExistence(timeout: 3))
        settle()
        try capture("02-workout")
    }

    func test03ClaudeProposal() throws {
        let app = launch(["-seedProposal"])
        let chip = app.buttons["today.proposal"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        XCTAssertTrue(element(app, "proposal.review").waitForExistence(timeout: 5))
        nudge(app, by: 22) // lifts the footnote out from behind the action bar
        try capture("03-claude-proposal")
    }

    /// Weekly sets under the recovery card. The strength seed fills the Strength Level card at the bottom, which
    /// otherwise asks for the owner's sex and birth year.
    func test04Body() throws {
        let app = launch(Self.fullHistory + ["-seedStrength"])
        app.tabBars.buttons["Body"].tap()
        let chest = element(app, "body.weeklySets.chest")
        scroll(app.collectionViews.firstMatch, to: chest)
        // The weekly-sets card starts just under the status bar: the weigh-ins above the recovery card can't sit
        // there, since the clock would be drawn over their text.
        position(app, chest, atY: 66)
        try capture("04-body")
    }

    func test04bRecoveryMap() throws {
        let app = launch(Self.fullHistory)
        let card = element(app, "today.recovery")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(element(app, "recovery.summary").waitForExistence(timeout: 5))
        settle()
        try capture("04b-recovery-map")
    }

    func test04cBodyWeight() throws {
        let app = launch(Self.fullHistory)
        app.tabBars.buttons["Body"].tap()
        XCTAssertTrue(element(app, "body.chart").waitForExistence(timeout: 5))
        settle()
        try capture("04c-body-weight")
    }

    func test05Log() throws {
        let app = launch(Self.fullHistory)
        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(element(app, "log.streak").waitForExistence(timeout: 5))
        settle()
        try capture("05-log")
    }

    func test06ClaudeConnect() throws {
        // A placeholder project URL, so the connector URL shown is not the local test server's.
        let app = launch([], environment: ["SUPABASE_URL": "https://your-project.supabase.co",
                                           "SUPABASE_ANON_KEY": "anon"])
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let claude = app.buttons["settings.claude"]
        XCTAssertTrue(claude.waitForExistence(timeout: 5))
        claude.tap()
        XCTAssertTrue(app.staticTexts["claude.url"].waitForExistence(timeout: 5))
        settle()
        try capture("06-claude-connect")
    }
}
