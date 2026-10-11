import XCTest

/// End-to-end sync against the LOCAL Supabase stack (run via `scripts/ios-test-sync.sh`, which passes the local
/// URL and public anon key as `TEST_RUNNER_SUPABASE_URL` / `TEST_RUNNER_SUPABASE_ANON_KEY`). Skipped otherwise, so
/// the hermetic suite (`scripts/ios-test.sh`) never touches the network.
@MainActor
final class SyncUITests: XCTestCase {
    static let password = "Passw0rd!"
    static let fixedNow = "2026-09-26T09:00:00Z"

    private var backend: [String: String] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["SUPABASE_URL"], let key = env["SUPABASE_ANON_KEY"], !url.isEmpty, !key.isEmpty else {
            throw XCTSkip("Local Supabase not configured; run scripts/ios-test-sync.sh")
        }
        backend = ["SUPABASE_URL": url, "SUPABASE_ANON_KEY": key]
    }

    // MARK: Tests

    func testWorkoutSyncsAcrossFreshInstall() {
        let email = "ui-\(UUID().uuidString.lowercased())@test.local"

        // 1. Fresh install, sign up.
        var app = launch(freshInstall: true)
        openAccount(app)
        submitCredentials(app, email: email, button: "account.signUp")
        waitForLabel(app.staticTexts["account.lastSync"], "Just now")
        waitForLabel(app.staticTexts["account.status"], "Up to date")
        backToLog(app)

        // 2. Log all bench sets from Today's routine and finish.
        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))
        app.startWorkout()
        XCTAssertTrue(app.buttons["workout.entry.0025"].waitForExistence(timeout: 5))
        app.buttons["workout.entry.0025"].tap()
        XCTAssertTrue(app.buttons["logging.logAll"].waitForExistence(timeout: 5))
        app.buttons["logging.logAll"].tap()
        app.buttons["logging.next"].tap()
        app.buttons["workout.finish"].tap()
        XCTAssertTrue(app.buttons["finish.discardEmpty"].waitForExistence(timeout: 3))
        app.buttons["finish.discardEmpty"].tap()
        XCTAssertTrue(app.buttons["summary.done"].waitForExistence(timeout: 5))
        app.buttons["summary.done"].tap()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))

        // Remember the logged sets as the detail screen shows them.
        app.tabBars.buttons["Log"].tap()
        let localSets = openOnlyWorkoutAndReadSets(app)
        XCTAssertFalse(localSets.isEmpty)
        app.buttons["detail.back"].tap()

        // 3. Sync now.
        openAccount(app)
        app.buttons["account.syncNow"].tap()
        waitForLabel(app.staticTexts["account.status"], "Up to date")

        // 4. Relaunch as a fresh install and sign in again.
        app.terminate()
        app = launch(freshInstall: true)
        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.staticTexts["log.empty.title"].waitForExistence(timeout: 5))
        openAccount(app)
        submitCredentials(app, email: email, button: "account.signIn")
        waitForLabel(app.staticTexts["account.status"], "Up to date")
        backToLog(app)

        // 5. The workout and its bench sets came back from the server.
        XCTAssertEqual(openOnlyWorkoutAndReadSets(app), localSets)
    }

    func testOfflineLoggingSyncsLater() {
        let email = "ui-\(UUID().uuidString.lowercased())@test.local"

        var app = launch(freshInstall: true)
        openAccount(app)
        submitCredentials(app, email: email, button: "account.signUp")
        waitForLabel(app.staticTexts["account.status"], "Up to date")
        app.terminate()

        // Offline: the weigh-in is saved locally and the banner says so.
        app = launch(freshInstall: false, extraEnvironment: ["GYM_SIMULATE_OFFLINE": "1"])
        addWeighIn(app, "81.4")
        app.tabBars.buttons["Log"].tap()
        let banner = app.descendants(matching: .any)["sync.banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertTrue(banner.label.contains("Offline"), banner.label)
        app.terminate()

        // Back online: Sync now pushes it and the banner goes away.
        app = launch(freshInstall: false)
        openAccount(app)
        app.buttons["account.syncNow"].tap()
        waitForLabel(app.staticTexts["account.status"], "Up to date")
        backToLog(app)
        XCTAssertTrue(app.descendants(matching: .any)["sync.banner"].waitForNonExistence(timeout: 5))
        app.terminate()

        // A fresh install of the same account shows the weigh-in.
        app = launch(freshInstall: true)
        openAccount(app)
        submitCredentials(app, email: email, button: "account.signIn")
        waitForLabel(app.staticTexts["account.status"], "Up to date")
        app.tabBars.buttons["Body"].tap()
        let entry = app.descendants(matching: .any)["body.entry.0"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertTrue(entry.label.contains("81.4"), entry.label)
    }

    /// Codex P1 #4: signing out mid-workout ends it; it doesn't come back as "Resume" or in the log.
    func testSignOutEndsTheWorkoutInProgress() {
        let email = "ui-\(UUID().uuidString.lowercased())@test.local"
        var app = launch(freshInstall: true)
        openAccount(app)
        submitCredentials(app, email: email, button: "account.signUp")
        waitForLabel(app.staticTexts["account.status"], "Up to date")
        backToLog(app)

        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))
        app.startWorkout()
        XCTAssertTrue(app.buttons["workout.close"].waitForExistence(timeout: 5))
        app.buttons["workout.close"].tap()
        XCTAssertTrue(app.buttons["today.resume"].waitForExistence(timeout: 5))

        openAccount(app)
        app.buttons["account.signOut"].tap()
        // A workout is in progress: the last sync can't upload it, so the explicit data-loss warning names it.
        let anyway = app.buttons["account.signOut.anyway"].firstMatch
        XCTAssertTrue(anyway.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1 workout in progress will be deleted from this iPhone."].exists)
        XCTAssertTrue(app.buttons["account.signOut.sync"].exists)
        anyway.tap()
        XCTAssertTrue(app.textFields["account.email"].waitForExistence(timeout: 10))
        backToLog(app)
        XCTAssertTrue(app.staticTexts["log.empty.title"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(app.buttons["today.resume"].waitForNonExistence(timeout: 5))
        app.terminate()

        app = launch(freshInstall: false)
        app.tabBars.buttons["Today"].tap()
        XCTAssertFalse(app.buttons["today.resume"].waitForExistence(timeout: 3))
    }

    /// Codex P1 #3: account A's session is revoked (data stays); signing in as B asks before removing A's data,
    /// and B never receives A's rows.
    func testSigningInToAnotherAccountRemovesTheOtherAccountsDataAfterConfirming() {
        let first = "ui-\(UUID().uuidString.lowercased())@test.local"
        let second = "ui-\(UUID().uuidString.lowercased())@test.local"
        var app = launch(freshInstall: true) // seeds the owner's routines
        openAccount(app)
        submitCredentials(app, email: first, button: "account.signUp")
        waitForLabel(app.staticTexts["account.status"], "Up to date")
        app.terminate()

        app = launch(freshInstall: false, forgetSession: true)
        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5)) // A's routines are still here
        openAccount(app)
        submitCredentials(app, email: second, button: "account.signUp", expecting: app.staticTexts["account.switch.message"])
        XCTAssertEqual(app.staticTexts["account.switch.message"].label,
                       "This iPhone has data from another account. Signing in will remove it from this iPhone.")
        app.buttons["account.switch.confirm"].tap()
        XCTAssertTrue(app.staticTexts["account.emailLabel"].waitForExistence(timeout: 15))
        waitForLabel(app.staticTexts["account.status"], "Up to date")
        backToLog(app)

        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(app.buttons["today.start"].waitForNonExistence(timeout: 5)) // A's routines are gone
        app.terminate()

        // B on a fresh (empty, unseeded) install pulls nothing: none of A's rows were uploaded under B.
        app = launch(freshInstall: true)
        openAccount(app)
        submitCredentials(app, email: second, button: "account.signIn")
        waitForLabel(app.staticTexts["account.status"], "Up to date")
        backToLog(app)
        app.tabBars.buttons["Today"].tap()
        XCTAssertFalse(app.buttons["today.start"].waitForExistence(timeout: 3))
    }

    // MARK: Helpers

    /// A fresh install wipes the store, the pull cursors and the session, and skips the owner seed on relaunches
    /// that should get everything from the server.
    private func launch(freshInstall: Bool, forgetSession: Bool = false,
                        extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-uiTesting", "-uiTestingBackend", "local", "-diskStore", "-fixedNow", Self.fixedNow]
        if freshInstall { args.append("-resetStore") }
        if forgetSession { args.append("-forgetSession") }
        if freshInstall, launchedOnce { args.append("-noSeed") }
        launchedOnce = true
        app.launchArguments = args
        app.launchEnvironment = backend.merging(extraEnvironment) { _, new in new }
        app.launch()
        return app
    }

    private var launchedOnce = false

    private func openAccount(_ app: XCUIApplication) {
        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.buttons["log.settings"].waitForExistence(timeout: 5))
        app.buttons["log.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    private func backToLog(_ app: XCUIApplication) {
        app.navigationBars["Settings"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["log.settings"].waitForExistence(timeout: 5))
    }

    private func submitCredentials(_ app: XCUIApplication, email: String, button: String,
                                   expecting: XCUIElement? = nil) {
        let emailField = app.textFields["account.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 10))
        type(email, into: emailField)
        let password = app.textFields["account.password"]
        type(Self.password, into: password)
        XCTAssertEqual(password.value as? String, Self.password)
        app.buttons[button].tap()
        XCTAssertTrue((expecting ?? app.staticTexts["account.emailLabel"]).waitForExistence(timeout: 15),
                      app.staticTexts["account.error"].exists ? app.staticTexts["account.error"].label : "no error")
    }

    /// Waits for keyboard focus before typing: keystrokes sent while focus is still moving (e.g. while the
    /// Passwords AutoFill bar appears) are dropped.
    private func type(_ text: String, into field: XCUIElement) {
        field.tap()
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)],
                                        timeout: 5), .completed)
        for character in text { field.typeText(String(character)) }
    }

    private func openOnlyWorkoutAndReadSets(_ app: XCUIApplication) -> [String] {
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(cards.count, 1)
        cards.firstMatch.tap()
        XCTAssertTrue(app.buttons["detail.menu"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Barbell Bench Press"].exists)
        return app.staticTexts.matching(NSPredicate(format: "label CONTAINS '\u{00D7}'")).allElementsBoundByIndex
            .map { $0.label }
    }

    private func addWeighIn(_ app: XCUIApplication, _ value: String) {
        app.tabBars.buttons["Body"].tap()
        XCTAssertTrue(app.buttons["body.addWeighIn"].waitForExistence(timeout: 5))
        app.buttons["body.addWeighIn"].tap()
        let field = app.textFields["weighin.value"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.press(forDuration: 1.0)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 1) { selectAll.tap() }
        field.typeText(value)
        app.dismissKeyboardIfPresent()
        app.buttons["weighin.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["body.entry.0"].waitForExistence(timeout: 5))
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 20,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label == %@", label)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
                                      timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected '\(label)', got '\(element.exists ? element.label : "<missing>")'",
                       file: file, line: line)
    }
}
