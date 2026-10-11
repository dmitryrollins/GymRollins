import XCTest

/// End-to-end proposal flow against the LOCAL Supabase stack (run via `scripts/ios-test-sync.sh`; skipped otherwise):
/// the owner signs up in the app (the seeded plan syncs up), a proposal is inserted as that user over PostgREST
/// (as the MCP tool would), the app pulls it and shows the chip, the owner applies it, and the server's row ends up
/// `applied`.
@MainActor
final class ProposalSyncUITests: XCTestCase {
    static let password = "Passw0rd!"
    private var url = ""
    private var anonKey = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["SUPABASE_URL"], let key = env["SUPABASE_ANON_KEY"], !url.isEmpty, !key.isEmpty else {
            throw XCTSkip("Local Supabase not configured; run scripts/ios-test-sync.sh")
        }
        self.url = url
        anonKey = key
    }

    func testProposalFromServerIsAppliedAndResolved() async throws {
        let email = "ui-\(UUID().uuidString.lowercased())@test.local"
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingBackend", "local", "-diskStore", "-resetStore",
                               "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launchEnvironment = ["SUPABASE_URL": url, "SUPABASE_ANON_KEY": anonKey]
        app.launch()

        // 1. Sign up; the seeded plan is pushed.
        openAccount(app)
        signUp(app, email: email)
        waitForLabel(app.staticTexts["account.status"], "Up to date")

        // 2. "Claude" proposes a heavier bench (inserted as the user, like the MCP tool does).
        let token = try await accessToken(email: email)
        let routines = try await rest("GET", "routines?select=id,name", token: token) as? [[String: Any]] ?? []
        let push = try XCTUnwrap(routines.first { $0["name"] as? String == "Push + Arms" }?["id"] as? String)
        let body: [String: Any] = ["summary": "Heavier bench", "changes": [[
            "id": "c1", "type": "weight", "routineId": push, "exerciseId": "0025", "weightKg": 65.77, "reason": "Top of range",
        ]]]
        let inserted = try await rest("POST", "proposals?select=id", token: token, body: body) as? [[String: Any]]
        let proposalId = try XCTUnwrap(inserted?.first?["id"] as? String)

        // 3. The app pulls it: chip on Today → review → apply.
        app.buttons["account.syncNow"].tap()
        waitForLabel(app.staticTexts["account.status"], "Up to date")
        app.tabBars.buttons["Today"].tap()
        let chip = app.buttons["today.proposal"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        XCTAssertTrue(app.buttons["proposal.apply"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["proposal.apply"].label, "Apply 1 change")
        app.buttons["proposal.apply"].tap()
        let bench = app.descendants(matching: .any)["today.row.0025"]
        let heavier = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '145 lb'"), object: bench)
        XCTAssertEqual(XCTWaiter().wait(for: [heavier], timeout: 5), .completed)

        // 4. The resolution syncs (debounced local change, or "Sync now"); Log's stack is still on Settings.
        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["account.syncNow"].tap()
        waitForLabel(app.staticTexts["account.status"], "Up to date")
        // "Up to date" is shown only after a round that pushed the local resolution (Apply left changes pending),
        // so the server already holds it: no polling needed.
        let rows = try await rest("GET", "proposals?select=status,applied_change_ids&id=eq.\(proposalId)",
                                  token: token) as? [[String: Any]]
        XCTAssertEqual(rows?.first?["status"] as? String, "applied")
        let plan = try await rest("GET", "routines?select=exercises&id=eq.\(push)", token: token) as? [[String: Any]]
        let exercises = plan?.first?["exercises"] as? [[String: Any]] ?? []
        let serverBench = exercises.first { $0["exercise_id"] as? String == "0025" }
        XCTAssertEqual((serverBench?["weight_kg"] as? Double) ?? 0, 65.77, accuracy: 0.01)
        XCTAssertNotNil(serverBench?["weight_set_at"] as? String)
    }

    // MARK: Helpers (local stack only)

    private func accessToken(email: String) async throws -> String {
        let json = try await request("POST", "\(url)/auth/v1/token?grant_type=password", token: nil,
                                     body: ["email": email, "password": Self.password]) as? [String: Any]
        return try XCTUnwrap(json?["access_token"] as? String)
    }

    private func rest(_ method: String, _ path: String, token: String, body: Any? = nil) async throws -> Any? {
        try await request(method, "\(url)/rest/v1/\(path)", token: token, body: body)
    }

    private func request(_ method: String, _ address: String, token: String?, body: Any?) async throws -> Any? {
        var req = URLRequest(url: try XCTUnwrap(URL(string: address)))
        req.httpMethod = method
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token ?? anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=representation", forHTTPHeaderField: "Prefer")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertTrue((200..<300).contains(code), "\(method) \(address): \(code) \(String(decoding: data, as: UTF8.self))")
        return data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data)
    }

    private func openAccount(_ app: XCUIApplication) {
        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.buttons["log.settings"].waitForExistence(timeout: 5))
        app.buttons["log.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
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
