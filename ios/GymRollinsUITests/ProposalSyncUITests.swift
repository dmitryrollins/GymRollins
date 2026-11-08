import XCTest

/// Claude end to end against a throwaway LOCAL Worker (run via `scripts/ios-test-sync.sh`, which passes its URL as
/// `TEST_RUNNER_API_URL`; Xcode hands it to the runner as `API_URL`). Skipped otherwise. Claude is played by
/// `ClaudeTestClient` (a real OAuth client and MCP caller); the owner signs up in the app, approves Claude's code in
/// Settings › Claude › Approve a connection, and reviews what Claude proposes.
@MainActor
final class ProposalSyncUITests: XCTestCase {
    static let password = "Passw0rd!"
    private var apiURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["API_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("No local Worker; run scripts/ios-test-sync.sh")
        }
        apiURL = url
    }

    /// Claude asks to connect, the owner approves its code in the sheet, Claude proposes a heavier bench, the app pulls
    /// it and the owner applies it; Claude then sees it applied, and the plan on the server has the new weight.
    func testClaudeConnectsThroughTheSheetAndItsProposalIsApplied() async throws {
        let email = "ui-\(UUID().uuidString.lowercased())@test.local"
        let app = launch()
        openSettings(app)
        signUp(app, email: email)
        waitForLabel(app.staticTexts["account.status"], "Up to date")

        // 1. Claude's sign-in page shows a code; the owner types it loosely and approves it.
        let claude = ClaudeTestClient(base: apiURL)
        let signIn = try await claude.startSignIn(clientId: try await claude.register())
        openApproveConnection(app)
        type(signIn.code.lowercased().replacingOccurrences(of: "-", with: ""), into: app.textFields["connect.code"])
        XCTAssertEqual(app.textFields["connect.code"].value as? String, signIn.code)
        waitForLabel(app.staticTexts["connect.client"], "Claude Code", timeout: 10)
        XCTAssertEqual(app.staticTexts["connect.host"].label, "127.0.0.1:53682")
        XCTAssertTrue(app.staticTexts["connect.warning"].exists, "a loopback callback isn't Claude's own host")
        app.buttons["connect.approve"].tap()
        waitForLabel(app.staticTexts["connect.result"], "Approved. Your browser returns to Claude in a moment.")
        let tokens = try await claude.exchange(signIn, code: try await claude.finish(signIn))
        app.buttons["connect.done"].tap()

        // 2. Claude proposes a heavier bench on the synced Push + Arms.
        let session = try await appSession(email: email)
        let routines = try await get("/v1/sync/routines?limit=500", token: session)["rows"] as? [[String: Any]] ?? []
        let push = try XCTUnwrap(routines.first { $0["name"] as? String == "Push + Arms" }?["id"] as? String)
        let proposed = try await claude.callTool(tokens.access, "propose_plan_changes", [
            "summary": "Heavier bench",
            "changes": [["id": "c1", "type": "weight", "routineId": push, "exerciseId": "0025", "weightKg": 65.77,
                         "reason": "Top of range"]],
        ])
        XCTAssertFalse(proposed.isError, "\(proposed.json)")
        let proposalId = try XCTUnwrap(proposed.json["proposal_id"] as? String)

        // 3. The app pulls it: chip on Today → review → apply.
        goBack(app, to: "Settings")
        syncNow(app)
        waitForLabel(app.staticTexts["account.status"], "Up to date")
        tapTab(app, "Today")
        let chip = app.buttons["today.proposal"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        XCTAssertTrue(app.buttons["proposal.apply"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["proposal.apply"].label, "Apply 1 change")
        app.buttons["proposal.apply"].tap()
        let bench = app.descendants(matching: .any)["today.row.0025"]
        let heavier = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '145 lb'"), object: bench)
        XCTAssertEqual(XCTWaiter().wait(for: [heavier], timeout: 5), .completed)

        // 4. The resolution syncs; Claude sees it applied, and the server's plan has the new weight.
        tapTab(app, "Log")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        syncNow(app)
        waitForLabel(app.staticTexts["account.status"], "Up to date")
        let seen = try await claude.callTool(tokens.access, "get_proposal", ["id": proposalId])
        XCTAssertEqual(seen.json["status"] as? String, "applied")
        let plan = try await get("/v1/sync/routines?limit=500", token: session)["rows"] as? [[String: Any]] ?? []
        let exercises = plan.first { $0["id"] as? String == push }?["exercises"] as? [[String: Any]] ?? []
        let serverBench = exercises.first { $0["exercise_id"] as? String == "0025" }
        XCTAssertEqual((serverBench?["weight_kg"] as? Double) ?? 0, 65.77, accuracy: 0.01)
    }

    /// Deny: the sheet says so, and Claude's callback gets `access_denied`.
    func testADeniedCodeSendsClaudeAway() async throws {
        let app = launch()
        openSettings(app)
        signUp(app, email: "ui-\(UUID().uuidString.lowercased())@test.local")
        let claude = ClaudeTestClient(base: apiURL)
        let signIn = try await claude.startSignIn(clientId: try await claude.register())
        openApproveConnection(app)
        type(signIn.code, into: app.textFields["connect.code"])
        XCTAssertTrue(app.buttons["connect.deny"].waitForExistence(timeout: 10))
        app.buttons["connect.deny"].tap()
        waitForLabel(app.staticTexts["connect.result"], "Denied. Claude wasn't given access.")
        let callback = try await claude.denial(signIn)
        XCTAssertEqual(callback.queryItems?.first { $0.name == "error" }?.value, "access_denied")
    }

    /// A code nobody is waiting with says why, and offers no Approve.
    func testAWrongCodeSaysSo() {
        let app = launch()
        openSettings(app)
        signUp(app, email: "ui-\(UUID().uuidString.lowercased())@test.local")
        openApproveConnection(app)
        type("ZZZZZZZZ", into: app.textFields["connect.code"])
        let error = app.staticTexts["connect.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.hasPrefix("No sign-in is waiting with this code."))
        XCTAssertFalse(app.buttons["connect.approve"].exists)
    }

    // MARK: Helpers (local Worker only)

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingBackend", "local", "-diskStore", "-resetStore",
                               "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launchEnvironment = ["API_URL": apiURL.absoluteString]
        app.launch()
        return app
    }

    /// The account's app session, as the app gets it: the bearer for `/v1` checks.
    private func appSession(email: String) async throws -> String {
        let json = try await request("POST", "/api/auth/sign-in/email", token: nil,
                                     body: ["email": email, "password": Self.password])
        return try XCTUnwrap(json["token"] as? String)
    }

    private func get(_ path: String, token: String) async throws -> [String: Any] {
        try await request("GET", path, token: token, body: nil)
    }

    private func request(_ method: String, _ path: String, token: String?, body: Any?) async throws -> [String: Any] {
        var req = URLRequest(url: try XCTUnwrap(URL(string: path, relativeTo: apiURL)?.absoluteURL))
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertTrue((200..<300).contains(code), "\(method) \(path): \(code) \(String(decoding: data, as: UTF8.self))")
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func openSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.buttons["log.settings"].waitForExistence(timeout: 5))
        app.buttons["log.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    /// Settings keeps its scroll position after the Claude row was reached; the account's Sync now is at the top.
    private func syncNow(_ app: XCUIApplication) {
        let button = app.buttons["account.syncNow"]
        scroll(app, to: button, from: .top)
        button.tap()
    }

    private func openApproveConnection(_ app: XCUIApplication) {
        // The Claude row sits below the fold of Settings' Form (rows load lazily): scroll until it is there.
        let claude = app.descendants(matching: .any)["settings.claude"]
        scroll(app, to: claude, from: .bottom)
        claude.tap()
        let approve = app.buttons["claude.approveConnection"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        approve.tap()
        XCTAssertTrue(app.textFields["connect.code"].waitForExistence(timeout: 5))
    }

    /// Added after review: the navigation bar's own back button (not whichever bar button comes first), and the
    /// screen it leads to.
    private func goBack(_ app: XCUIApplication, to title: String, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "No back button", file: file, line: line)
        back.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "Back didn't reach \(title)",
                      file: file, line: line)
    }

    /// Added in plan 30: taps a tab even when iOS 26 has minimized the tab bar. Scrolling a list down minimizes it
    /// (`RootView`'s `.tabBarMinimizeBehavior(.onScrollDown)`) to the selected tab alone, and the slow swipes `scroll`
    /// makes don't bring it back. A quick swipe down does, as it does for a person.
    private func tapTab(_ app: XCUIApplication, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let tab = app.tabBars.buttons[name]
        for _ in 0..<3 where !tab.exists {
            let list = app.collectionViews.firstMatch
            (list.exists ? list : app).swipeDown()
        }
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "The \(name) tab isn't in the tab bar", file: file, line: line)
        tab.tap()
    }

    enum ListEnd { case top, bottom }

    /// Added after review: the most slow swipes `scroll` makes. Settings is about two screens long.
    private static let maxSwipes = 15

    /// Added after review: scrolls Settings' Form with slow swipes until `element` is on screen and hittable, at most
    /// `maxSwipes` times, else fails saying so. A row the Form hasn't loaded yet (it loads lazily) is sought toward
    /// the `end` it sits at; a loaded one off screen is sought on the side it lies, which undoes an overshoot.
    private func scroll(_ app: XCUIApplication, to element: XCUIElement, from end: ListEnd,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<Self.maxSwipes {
            let area = visibleArea(app)
            if element.exists, element.isHittable, area.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) {
                return
            }
            let list = app.collectionViews.firstMatch
            let surface = list.exists ? list : app
            let above = element.exists ? element.frame.midY < area.minY : end == .top
            if above { surface.swipeDown(velocity: .slow) } else { surface.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(element.exists && element.isHittable,
                      "\(element.description) isn't on screen after \(Self.maxSwipes) slow swipes", file: file, line: line)
    }

    /// The part of the screen between the navigation bar and the tab bar, where a row can be tapped.
    private func visibleArea(_ app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch.frame
        let bar = app.navigationBars.firstMatch
        let tabs = app.tabBars.firstMatch
        let top = bar.exists ? bar.frame.maxY : window.minY
        let bottom = tabs.exists ? tabs.frame.minY : window.maxY
        return CGRect(x: window.minX, y: top, width: window.width, height: max(0, bottom - top))
    }

    private func signUp(_ app: XCUIApplication, email: String) {
        let emailField = app.textFields["account.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 10))
        type(email, into: emailField)
        type(Self.password, into: app.textFields["account.password"])
        app.buttons["account.signUp"].tap()
        XCTAssertTrue(app.staticTexts["account.emailLabel"].waitForExistence(timeout: 15))
    }

    private func type(_ text: String, into field: XCUIElement) {
        field.tap()
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [focused], timeout: 5), .completed)
        for character in text { field.typeText(String(character)) }
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 20) {
        let predicate = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [predicate], timeout: timeout), .completed,
                       "Expected '\(label)', got '\(element.exists ? element.label : "<missing>")'")
    }
}
