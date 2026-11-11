import XCTest

/// Runs Xcode's built-in accessibility audit (`performAccessibilityAudit`) on every main screen: contrast, missing
/// labels, hit regions, clipped text, Dynamic Type support, trait/element problems. Issues were fixed in the app;
/// what remains are audit false positives, excluded in `exclusionReason` with the evidence. Any other issue fails
/// the test, and every issue (excluded or not) is printed as `A11Y-AUDIT …`.
@MainActor
final class AccessibilityAuditUITests: XCTestCase {
    /// Keeps going after one screen's audit fails, so a multi-screen test reports the later screens too.
    override func setUp() { continueAfterFailure = true }

    private func launch(_ extra: [String] = ["-seedHistory"]) -> XCUIApplication {
        XCUIApplication.launchReady(extra)
    }

    /// Audits the current screen, printing every issue (so a failing run lists all of them, not just the first).
    private func audit(_ app: XCUIApplication, _ screen: String, file: StaticString = #filePath, line: UInt = #line) {
        let windowHeight = app.windows.firstMatch.frame.height
        var reported: [String] = []
        do {
            try app.performAccessibilityAudit { issue in
                let summary = "\(issue.compactDescription) on " + (issue.element.map {
                    "type=\($0.elementType.rawValue) id='\($0.identifier)' label='\($0.label)' frame=\($0.frame)"
                } ?? "no element")
                if let reason = Self.exclusionReason(issue, windowHeight: windowHeight, screen: screen) {
                    print("A11Y-AUDIT [\(screen)] excluded (\(reason)): \(summary)")
                } else {
                    print("A11Y-AUDIT [\(screen)] ISSUE: \(summary)")
                    reported.append(summary)
                }
                // Always "handled" so the audit keeps going and one run lists every issue; real ones fail below.
                return true
            }
        } catch {
            XCTFail("[\(screen)] accessibility audit: \(error)", file: file, line: line)
        }
        if !reported.isEmpty {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "audit-issue-\(screen)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertTrue(reported.isEmpty, "[\(screen)] accessibility issues:\n" + reported.joined(separator: "\n"),
                      file: file, line: line)
    }

    /// Height of the bottom band covered by the floating bottom bar / tab bar and iOS 26's scroll-edge effect. Today's
    /// Start Workout bar begins near y=795 of 956, so a row ending just below that is sampled half-covered.
    static let bottomEdgeBand: CGFloat = 165

    /// Height of the top band covered by the navigation bar and its scroll-edge effect (the bar ends near 118 pt).
    static let topEdgeBand: CGFloat = 120

    /// Labels whose contrast was measured from simulator screenshots (default text size) and passes 4.5:1, but which
    /// the audit flags because it samples the Liquid Glass capsule behind them: "How-To" 16.0:1 (white on the dark
    /// glass capsule over the logging hero). The injury note's "Until" toggle label (only in `LimitsEditor`) is 19.6:1
    /// (white on #0B0B10), flagged on every run since 7 Nov, on plan 24's commit too.
    static let measuredContrastLabels: Set<String> = ["How-To", "Until"]

    /// Plan 32, Settings › AI agents: the switch labels (white on #0B0B10, ~17:1 as the Claude screen's note above
    /// measured them) are flagged for contrast whichever row sits under the navigation bar's fade or beside the Add
    /// workouts row's two lines, a different one on each run.
    static let agentSwitchLabels: Set<String> = [
        "Read workouts and sets", "Read bodyweight", "Read your plan and profile", "Gyms", "Add workouts",
        "Propose plan changes", "Apply changes without asking",
    ]

    /// Plan 32's footers under those switches (and plan 33's auto-apply note, the same footer text): the system's
    /// secondary label colour, measured from a simulator screenshot at 6.3:1 on #0B0B10 (peak glyph pixel
    /// (145,145,153)), flagged only by the audit's sampling.
    static let measuredContrastFooterIdentifiers: Set<String> = [
        "claude.gymsNote", "agents.logWorkoutsNote", "agents.autoApplyNote",
    ]

    /// Use with Claude's footer (plan 32): a plain `Text` in a text style that scales, flagged for clipping and Dynamic
    /// Type only while the longer AI agents screen leaves it under the tab bar's scroll-edge effect.
    static let underTabBarFooterIdentifier = "claude.coach.note"

    /// The audits of Settings › AI agents, the only screens the switch-label exclusions apply to: elsewhere a label
    /// such as "Gyms" is a different element (added after review).
    static func isAgentsScreen(_ screen: String) -> Bool {
        screen == "Claude connection" || screen == "Use with Claude" || screen.hasPrefix("AI agents")
    }

    /// Buttons measured the same way, for labels too common to exclude by name. The add flow's "Save" is 7.14:1 (white on
    /// #A72431), 5.6:1 at the capsule's rim, and the audit flags it only sometimes, when other tests ran first. The report
    /// sheet's "Send report" is the same button, also 7.14:1, flagged on 3 runs of 9. The injury note's "Save" is the
    /// same button again, 7.1:1, flagged with "Until".
    static let measuredContrastIdentifiers: Set<String> = ["addEquipment.save", "report.send", "limits.edit.save"]

    /// Why an issue is a false positive, or nil when it's a real issue. Each exclusion is narrow and justified.
    static func exclusionReason(_ issue: XCUIAccessibilityAuditIssue, windowHeight: CGFloat,
                                screen: String) -> String? {
        guard let element = issue.element else {
            // Raised against system chrome with no element (status bar, scroll-edge effect views).
            return "system chrome"
        }
        // The connector URL is read out literally on purpose: it is what the user pastes into Claude, and the screenshot
        // shows the whole address in a monospaced line above its "Copy URL" button.
        if element.identifier == "claude.url", issue.compactDescription.contains("human-readable") {
            return "a URL read literally"
        }
        let type = element.elementType
        let frame = element.frame
        let agentSwitchLabel = isAgentsScreen(screen) && type == .staticText && agentSwitchLabels.contains(element.label)
        switch issue.auditType {
        case .contrast:
            // iOS 26 dims scrolled content under the floating bottom bar and tab bar (scroll-edge effect) by design;
            // the same rows read at full contrast once scrolled up. The bar's own prominent buttons measured 5.6:1
            // (white on #C22F3B) from screenshots.
            if frame.maxY > windowHeight - bottomEdgeBand { return "under bottom scroll-edge effect" }
            // The same effect dims rows scrolled up under the navigation bar, which a longer Settings list now does. Like
            // the bottom band, a row only partly under it is sampled half-dimmed: on the Claude screen whichever row
            // straddles the bar's edge was flagged (toggle labels, "Show all", the prompt text), all 17:1 when measured.
            if frame.minY < topEdgeBand { return "under top scroll-edge effect" }
            if measuredContrastLabels.contains(element.label) { return "measured on glass" }
            if agentSwitchLabel { return "measured switch label" }
            if measuredContrastFooterIdentifiers.contains(element.identifier) { return "measured footer" }
            if measuredContrastIdentifiers.contains(element.identifier) { return "measured on glass" }
            // `.searchable`'s placeholder is system-styled.
            if type == .searchField { return "system search field" }
            return nil
        case .textClipped:
            // UITextField/UISearchTextField are flagged regardless of content (empty fields, 1–3 digit values in
            // 44–58 pt fields); screenshots show the full text at default and AX-XL sizes.
            if type == .textField || type == .searchField { return "UITextField false positive" }
            // Plan 32: the AI agents screen is long enough that Use with Claude's footer sits under the tab bar's
            // scroll-edge effect, and the switch labels above it are flagged although the screenshots show every
            // switch label whole, on one line.
            if element.identifier == underTabBarFooterIdentifier { return "under bottom scroll-edge effect" }
            if agentSwitchLabel { return "switch label shown whole" }
            // The glass capsule's label: identical SecondaryGlassButton "Skip for now" below it isn't flagged, and the
            // screenshot shows the whole label.
            if element.identifier == "onboarding.email" { return "glass button false positive" }
            return nil
        case .hitRegion:
            // ProgressView is not interactive (no action), so it has no hit region to size.
            if type == .progressIndicator { return "non-interactive progress bar" }
            return nil
        case .dynamicType:
            // "Partially unsupported": the element uses a text style and does scale (checked in code and in the AX-XL
            // screenshots); the audit flags that a single-line system row/label truncates at the very largest size.
            // Fixed-size ("unsupported") fonts are still failures.
            if issue.compactDescription.contains("partially") { return "scales; truncates at AX5" }
            // Plan 32: Use with Claude's footer is a plain `Text` (a text style that scales); it is flagged only while
            // it sits under the tab bar's scroll-edge effect.
            if element.identifier == underTabBarFooterIdentifier { return "under bottom scroll-edge effect" }
            // Toolbar "Close" is a system bar button.
            if type == .button && element.identifier == "workout.close" { return "system toolbar button" }
            return nil
        default:
            return nil
        }
    }

    // MARK: Screens

    func testTodayAudit() {
        let app = launch()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))
        audit(app, "Today")
    }

    func testLimitsCheckInAudit() {
        let app = launch(["-seedHistory", "-seedLimitsDue"])
        XCTAssertTrue(app.buttons["limits.yes"].waitForExistence(timeout: 5))
        waitUntilSettled(app.buttons["limits.yes"])
        audit(app, "Limits check-in")
        app.buttons["limits.yes"].tap()
        XCTAssertTrue(app.buttons["limits.resume.0"].waitForExistence(timeout: 5))
        waitUntilSettled(app.buttons["limits.resume.0"])
        audit(app, "Limits resume")
    }

    func testLimitsSettingsAudit() {
        let app = launch()
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.limits"]
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.buttons["limits.edit.save"].waitForExistence(timeout: 5))
        waitUntilSettled(app.buttons["limits.edit.save"])
        audit(app, "Limits settings")
    }

    /// Today's exercise screen before the workout (plan mode).
    func testPlanScreenAudit() {
        let app = launch()
        let row = app.buttons["today.row.0025"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["logging.startWorkout"].waitForExistence(timeout: 5))
        audit(app, "Plan screen")
    }

    /// My Plan's week, a day's editor and Saved workouts.
    func testMyPlanAudit() {
        let app = launch()
        app.buttons["today.myPlan"].tap()
        let monday = app.buttons["plan.day.1"]
        XCTAssertTrue(monday.waitForExistence(timeout: 5))
        waitUntilSettled(monday)
        audit(app, "My Plan")
        monday.tap()
        XCTAssertTrue(app.buttons["day.workout"].waitForExistence(timeout: 5))
        waitUntilSettled(app.buttons["day.workout"])
        audit(app, "Day editor")
        app.buttons["Cancel"].tap()
        let saved = app.buttons["plan.savedWorkouts"]
        app.scrollToHittable(saved)
        saved.tap()
        XCTAssertTrue(app.buttons["plan.addRoutine"].waitForExistence(timeout: 5))
        waitUntilSettled(app.buttons["plan.addRoutine"])
        audit(app, "Saved workouts")
    }

    /// Waits for Today's title between the swipes: two quick swipes once stayed on Sunday.
    private func waitForTitle(_ app: XCUIApplication, _ text: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let title = app.staticTexts["today.title"].firstMatch
        let predicate = NSPredicate(format: "label == %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: title)], timeout: 5)
        XCTAssertEqual(result, .completed, "title was '\(title.label)'", file: file, line: line)
    }

    /// A later day on Today, changed for that date.
    func testLaterDayAudit() {
        let app = launch()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))
        app.scrollViews.firstMatch.swipeLeft()
        waitForTitle(app, "Tomorrow")
        app.scrollViews.firstMatch.swipeLeft()
        waitForTitle(app, "Monday")
        let menu = app.buttons["today.row.menu.0025"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let delete = app.buttons["Delete from Workout"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(app.buttons["today.backToToday"].waitForExistence(timeout: 5))
        waitUntilSettled(app.buttons["today.backToToday"])
        audit(app, "Later day")
    }

    func testWorkoutOverviewAndLoggingAudit() {
        let app = launch()
        app.startWorkout()
        audit(app, "Workout overview")
        app.openExercise("0025")
        audit(app, "Logging")
        app.buttons["logging.logSet"].tapCenter()
        XCTAssertTrue(app.buttons["logging.rest.skip"].waitForExistence(timeout: 3))
        audit(app, "Logging (resting)")
    }

    func testSummaryAudit() {
        let app = launch()
        app.startWorkout()
        app.openExercise("0025")
        app.buttons["logging.logAll"].tapCenter()
        app.buttons["logging.next"].tapCenter()
        app.buttons["workout.finish"].tapCenter()
        XCTAssertTrue(app.buttons["finish.discardEmpty"].waitForExistence(timeout: 3))
        app.buttons["finish.discardEmpty"].tap()
        XCTAssertTrue(app.staticTexts["summary.title"].waitForExistence(timeout: 5))
        audit(app, "Summary")
    }

    func testLogAudit() {
        let app = launch()
        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.buttons["log.settings"].waitForExistence(timeout: 5))
        audit(app, "Log")
    }

    func testBodyAudit() {
        let app = launch(["-seedHistory", "-seedBodyweight"])
        app.tabBars.buttons["Body"].tap()
        XCTAssertTrue(app.buttons["body.addWeighIn"].waitForExistence(timeout: 5))
        audit(app, "Body")
    }

    func testLibraryAudit() {
        let app = launch()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        audit(app, "Library")
    }

    func testSettingsAudit() {
        let app = launch()
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        audit(app, "Settings")
    }

    func testClaudeConnectionAudit() {
        let app = launch()
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.claude"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let gyms = app.switches["claude.perm.readGyms"]
        for _ in 0..<12 where !gyms.isHittable { app.swipeUp() }
        XCTAssertTrue(gyms.isHittable)
        XCTAssertEqual(gyms.value as? String, "1")
        audit(app, "Claude connection")
    }

    func testUseWithClaudeAudit() {
        let app = launch()
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.claude"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let coach = app.buttons["claude.coach.copy"]
        for _ in 0..<12 where !coach.isHittable { app.swipeUp() }
        XCTAssertTrue(coach.isHittable)
        audit(app, "Use with Claude")
    }

    /// Plan 32: the agent rows, Disconnect's confirmation, and Add workouts.
    func testAgentsAudit() {
        let app = launch(["-seedHistory", "-fakeAgents", "-seedProposal"])
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.claude"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tap()
        let disconnect = app.buttons["agents.disconnect.MuseFakeClientId"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        waitUntilSettled(disconnect)
        audit(app, "AI agents")

        let add = app.switches["agents.perm.logWorkouts"]
        for _ in 0..<12 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.isHittable)
        waitUntilSettled(add)
        audit(app, "AI agents: what agents can do")

        for _ in 0..<12 where !disconnect.isHittable { app.swipeDown() }
        disconnect.tap()
        let confirm = app.buttons["agents.disconnect.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        waitUntilSettled(confirm)
        audit(app, "AI agents: disconnect one")
    }

    /// Plan 32: the workout screen with "Added by Muse". This is the screen's first audit: an issue on any element other
    /// than `detail.addedBy` predates this plan (Step 2 says what to do).
    func testWorkoutAddedByAnAgentAudit() {
        let app = launch(["-seedAgentWorkout"])
        app.tabBars.buttons["Log"].tap()
        let card = app.descendants(matching: .any)["log.workout.AD0ED000-0000-4000-8000-000000000001"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        let added = app.staticTexts["detail.addedBy"]
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        waitUntilSettled(added)
        audit(app, "Workout added by an agent")
    }

    func testModerationAudit() {
        let app = launch(["-fakeGymCatalog", "-fakeSignedIn", "-fakeGymAdmin"])
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.moderation"]
        app.scrollToHittable(row) // below the fold since Settings grew (Training, AI agents)
        row.tap()
        let remove = app.buttons["moderation.remove.00000000-0000-4000-8000-0000000000D1"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        audit(app, "Moderation")
        remove.tap()
        XCTAssertTrue(app.buttons["moderation.removeConfirm.00000000-0000-4000-8000-0000000000D1"]
            .waitForExistence(timeout: 5))
        audit(app, "Moderation: confirm a removal")
    }

    func testUnblockEveryoneAudit() {
        let app = launch(["-fakeGymCatalog", "-fakeSignedIn"])
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.unblockAll"]
        var swipes = 0
        while !(row.exists && row.isHittable) && swipes < 15 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let confirm = app.buttons["settings.unblockAll.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let result = app.staticTexts["settings.unblockAll.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        waitUntilSettled(result)
        audit(app, "Settings: unblocked")
    }

    /// Waits until `element` has stopped moving and the dialog's dimming has faded. Audited mid-scroll, the section
    /// headers sampled the fade and failed contrast at a different place on every run.
    private func waitUntilSettled(_ element: XCUIElement) {
        var last = element.frame
        for _ in 0..<8 {
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 0.5)
            if element.frame == last { break }
            last = element.frame
        }
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "fade")], timeout: 0.5)
    }

    func testProposalReviewAudit() {
        let app = launch(["-seedProposal"])
        let chip = app.buttons["today.proposal"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        XCTAssertTrue(app.descendants(matching: .any)["proposal.review"].waitForExistence(timeout: 5))
        audit(app, "Proposal review")
    }

    func testOnboardingWelcomeAndProfileAudit() {
        let app = XCUIApplication.launchReady(["-onboarding"]) { $0.buttons["onboarding.skip"] }
        audit(app, "Onboarding welcome")
        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(app.buttons["setup.continue"].waitForExistence(timeout: 5))
        audit(app, "Onboarding profile")
    }

    // MARK: Gyms

    private func openPicker(_ app: XCUIApplication) {
        app.buttons["today.gymChip"].tap()
        XCTAssertTrue(app.buttons["gymPicker.close"].waitForExistence(timeout: 5))
    }

    func testTodayWithSwappedRowsAudit() {
        let app = launch(["-seedGym"])
        XCTAssertTrue(app.descendants(matching: .any)["today.gymNote"].waitForExistence(timeout: 5))
        audit(app, "Today (gym marks)")
    }

    func testGymPickerAudit() {
        let app = launch(["-seedGym"])
        openPicker(app)
        audit(app, "Gym picker")
    }

    func testGymEquipmentAudit() {
        let app = launch(["-seedGym"])
        openPicker(app)
        app.buttons["gymPicker.currentEquipment"].tap()
        XCTAssertTrue(app.staticTexts["gymEquipment.coverage.chest"].waitForExistence(timeout: 10))
        audit(app, "Gym equipment")
    }

    func testGymEquipmentWithSamplePhotosAudit() {
        let app = launch(["-seedGym", "-uiTestingPhotos"])
        openPicker(app)
        app.buttons["gymPicker.currentEquipment"].tap()
        XCTAssertTrue(app.staticTexts["gymEquipment.coverage.chest"].waitForExistence(timeout: 10))
        let tile = app.buttons["gymEquipment.listing.flat-bench"]
        XCTAssertTrue(NSPredicate(format: "label CONTAINS 'Sample'").evaluate(with: tile) ||
                      XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label CONTAINS 'Sample'"),
                                                         evaluatedWith: tile)], timeout: 10) == .completed)
        audit(app, "Gym equipment with sample photos")
        tile.tap()
        XCTAssertTrue(app.staticTexts["listing.samplePhotoNote"].waitForExistence(timeout: 10))
        audit(app, "Listing detail with a sample photo")
    }

    func testAddEquipmentAudit() {
        let app = launch(["-seedGym", "-gymPhotoFixture"])
        openPicker(app)
        app.buttons["gymPicker.currentEquipment"].tap()
        app.buttons["gymEquipment.add"].tap()
        XCTAssertTrue(app.buttons["addEquipment.skip"].waitForExistence(timeout: 5))
        audit(app, "Add equipment: photo")
        app.buttons["addEquipment.library"].tap()
        let search = app.textFields["addEquipment.kindSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        audit(app, "Add equipment: kind")
        search.tap()
        search.typeText("lat")
        app.buttons["addEquipment.kind.lat-pulldown"].tapCenter()
        XCTAssertTrue(app.staticTexts["addEquipment.stackValue"].waitForExistence(timeout: 5))
        audit(app, "Add equipment: details")
    }

    // MARK: Shared gyms (-fakeGymCatalog)

    private func openSharedEquipment(_ app: XCUIApplication) {
        openPicker(app)
        app.buttons["gymPicker.currentEquipment"].tap()
        XCTAssertTrue(app.buttons["gymEquipment.listing.lat-pulldown"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["gymEquipment.coverage.chest"].waitForExistence(timeout: 10))
    }

    private func openListing(_ app: XCUIApplication, _ tile: XCUIElement) {
        _ = tile.waitForExistence(timeout: 5)
        app.scrollToHittable(tile) // Benches is below the fold; Cables is above it once scrolled there
        tile.tap()
        XCTAssertTrue(app.descendants(matching: .any)["listing.shareStatus"].waitForExistence(timeout: 5))
    }

    func testGymPickerWithSharedGymAudit() {
        let app = launch(["-fakeGymCatalog"])
        openPicker(app)
        audit(app, "Gym picker with a shared gym")
    }

    func testSharedGymEquipmentAudit() {
        let app = launch(["-fakeGymCatalog"])
        openSharedEquipment(app)
        audit(app, "Shared gym equipment")
    }

    func testSharedListingDetailsAudit() {
        let app = launch(["-fakeGymCatalog"])
        openSharedEquipment(app)
        openListing(app, app.buttons["gymEquipment.listing.lat-pulldown"])
        audit(app, "Listing detail: someone else's")
        app.navigationBars.buttons.firstMatch.tap()
        openListing(app, app.buttons["gymEquipment.listing.flat-bench"])
        XCTAssertTrue(app.descendants(matching: .any)["listing.catalogPhoto"].waitForExistence(timeout: 10))
        audit(app, "Listing detail: only me, with a borrowed photo")
        app.navigationBars.buttons.firstMatch.tap()
        openListing(app, app.buttons["gymEquipment.listing.barbell"])
        audit(app, "Listing detail: couldn't upload")
        app.navigationBars.buttons.firstMatch.tap()
        let waiting = app.buttons.matching(identifier: "gymEquipment.listing.cable-station")
            .matching(NSPredicate(format: "label CONTAINS 'Needs a choice'")).firstMatch
        openListing(app, waiting)
        XCTAssertTrue(app.buttons["listing.shareAnyway"].exists)
        audit(app, "Listing detail: may already be there")
    }

    func testReportSheetAndBlockCardAudit() {
        let app = launch(["-fakeGymCatalog", "-fakeSignedIn"])
        openSharedEquipment(app)
        openListing(app, app.buttons["gymEquipment.listing.lat-pulldown"])
        app.buttons["listing.menu"].tap()
        app.buttons["listing.block"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["listing.block.message"].waitForExistence(timeout: 5))
        audit(app, "Listing detail: hide everything from this user")
        app.buttons["listing.block.cancel"].tap()
        app.buttons["listing.menu"].tap()
        app.buttons["listing.report"].tap()
        XCTAssertTrue(app.buttons["report.send"].waitForExistence(timeout: 5))
        audit(app, "Report sheet")
        app.buttons["report.reason.other"].tap()
        audit(app, "Report sheet: a reason picked")
    }

    func testAddEquipmentSharingAudit() {
        let app = launch(["-fakeGymCatalog", "-gymPhotoFixture"])
        openSharedEquipment(app)
        app.buttons["gymEquipment.add"].tap()
        app.buttons["addEquipment.skip"].tapWhenHittable()
        let search = app.textFields["addEquipment.kindSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap()
        search.typeText("lat")
        app.buttons["addEquipment.kind.lat-pulldown"].tapCenter()
        XCTAssertTrue(app.buttons["add.confirm.00000000-0000-4000-8000-0000000000B1"].waitForExistence(timeout: 5))
        audit(app, "Add equipment: already here, with someone else's")
        app.buttons["addEquipment.different"].tapCenter()
        XCTAssertTrue(app.buttons["add.visibility.shared"].waitForExistence(timeout: 5))
        audit(app, "Add equipment: who sees it")
    }

    func testSignInForSharingAudit() {
        let app = launch(["-fakeGymCatalog"])
        openSharedEquipment(app)
        openListing(app, app.buttons["gymEquipment.listing.lat-pulldown"])
        app.buttons["listing.confirm"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["signInForSharing.title"].waitForExistence(timeout: 5))
        audit(app, "Sign in to share")
    }

    /// The Build sheet remembers its last chips, so leave only `chip` selected.
    private func selectOnly(_ app: XCUIApplication, _ chip: String) {
        for name in ["chest", "back", "shoulders", "arms", "legs", "core"] {
            let button = app.buttons["build.chip.\(name)"]
            for _ in 0..<4 where !button.isHittable { app.swipeUp() }
            if button.isSelected != (name == chip) { button.tap() }
        }
    }

    func testBuildSheetAudit() {
        let app = launch(["-seedGym"])
        app.buttons["today.build"].tapCenter()
        XCTAssertTrue(app.buttons["build.go"].waitForExistence(timeout: 5))
        selectOnly(app, "back")
        audit(app, "Build workout")
    }

    func testBuildResultAudit() {
        let app = launch(["-seedGym"])
        app.buttons["today.build"].tapCenter()
        selectOnly(app, "back")
        app.buttons["build.length.60"].tap()
        app.buttons["build.go"].tapCenter()
        XCTAssertTrue(app.descendants(matching: .any)["build.title"].waitForExistence(timeout: 10))
        audit(app, "Build result")
    }

    func testShareWorkoutAudit() {
        let app = launch()
        let share = app.buttons["today.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        for _ in 0..<6 where !share.isHittable { app.swipeUp() }
        share.tap()
        XCTAssertTrue(app.images["share.qr"].waitForExistence(timeout: 10))
        audit(app, "Share workout")
    }

    func testIncomingWorkoutAudit() throws {
        let app = launch()
        app.open(try XCTUnwrap(URL(string: "gymrollins://w#1.0025_3_8-10.0313_3_10.ZZZZ_3_10")))
        XCTAssertTrue(app.buttons["incoming.use"].waitForExistence(timeout: 10))
        audit(app, "Incoming workout")
    }

    func testIncomingWorkoutMessageAudit() throws {
        let app = launch()
        app.open(try XCTUnwrap(URL(string: "gymrollins://w#nonsense")))
        XCTAssertTrue(app.staticTexts["incoming.message"].waitForExistence(timeout: 10))
        audit(app, "Incoming workout message")
    }

    // MARK: VoiceOver text

    /// Set rows read as one summary ("Warm-up set 1, 10 reps, 45 pounds, done"), and the rest timer exposes the
    /// spoken remaining time as its value.
    func testSetRowsAndRestTimerSpeak() {
        let app = launch()
        app.startWorkout()
        app.openExercise("0025")
        let first = app.descendants(matching: .any)["logging.set.0.summary"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.label, "Warm-up set 1, 10 reps, 45 pounds, current set")
        XCTAssertEqual(app.descendants(matching: .any)["logging.set.2.summary"].label,
                       "Set 1, 8 reps, 135 pounds, not done")
        app.buttons["logging.logSet"].tapCenter()
        let rest = app.descendants(matching: .any)["logging.rest"]
        XCTAssertTrue(rest.waitForExistence(timeout: 5))
        XCTAssertEqual(rest.label, "Rest timer")
        XCTAssertTrue((rest.value as? String)?.hasSuffix("remaining") == true, "\(String(describing: rest.value))")
        XCTAssertEqual(first.label, "Warm-up set 1, 10 reps, 45 pounds, done")
    }

    // MARK: Bottom bar

    /// iOS 26 draws a scroll-edge effect under `.safeAreaInset` bottom bars. In the hierarchy it is a stack of
    /// unlabeled, non-element container views over the bar (0,726 → 402×148 on iPhone 17 Pro), so VoiceOver can't
    /// focus it and it doesn't take the button's activation; the button is hittable and a plain `.tap()` works.
    /// (`tapCenter` stays in the suite: under load XCUITest's hit-point search can still settle on the frame corner.)
    func testBottomBarPrimaryButtonIsHittableAtItsCentre() {
        let app = launch()
        let start = app.buttons["today.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isHittable)
        start.tap()
        XCTAssertTrue(app.staticTexts["workout.clock"].waitForExistence(timeout: 10), "plain tap on Start was lost")
    }
}
