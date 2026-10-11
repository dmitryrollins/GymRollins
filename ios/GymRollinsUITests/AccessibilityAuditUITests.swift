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
                if let reason = Self.exclusionReason(issue, windowHeight: windowHeight) {
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
        XCTAssertTrue(reported.isEmpty, "[\(screen)] accessibility issues:\n" + reported.joined(separator: "\n"),
                      file: file, line: line)
    }

    /// Height of the bottom band covered by the floating bottom bar / tab bar and iOS 26's scroll-edge effect.
    static let bottomEdgeBand: CGFloat = 150

    /// Labels whose contrast was measured from simulator screenshots (default text size) and passes 4.5:1, but which
    /// the audit flags because it samples the Liquid Glass capsule behind them: "How-To" 16.0:1 (white on the dark
    /// glass capsule over the logging hero).
    static let measuredContrastLabels: Set<String> = ["How-To"]

    /// Why an issue is a false positive, or nil when it's a real issue. Each exclusion is narrow and justified.
    static func exclusionReason(_ issue: XCUIAccessibilityAuditIssue, windowHeight: CGFloat) -> String? {
        guard let element = issue.element else {
            // Raised against system chrome with no element (status bar, scroll-edge effect views).
            return "system chrome"
        }
        let type = element.elementType
        let frame = element.frame
        switch issue.auditType {
        case .contrast:
            // iOS 26 dims scrolled content under the floating bottom bar and tab bar (scroll-edge effect) by design;
            // the same rows read at full contrast once scrolled up. The bar's own prominent buttons measured 5.6:1
            // (white on #C22F3B) from screenshots.
            if frame.maxY > windowHeight - bottomEdgeBand { return "under bottom scroll-edge effect" }
            if measuredContrastLabels.contains(element.label) { return "measured on glass" }
            // `.searchable`'s placeholder is system-styled.
            if type == .searchField { return "system search field" }
            return nil
        case .textClipped:
            // UITextField/UISearchTextField are flagged regardless of content (empty fields, 1–3 digit values in
            // 44–58 pt fields); screenshots show the full text at default and AX-XL sizes.
            if type == .textField || type == .searchField { return "UITextField false positive" }
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

    /// Today's exercise screen before the workout (plan mode).
    func testPlanScreenAudit() {
        let app = launch()
        let row = app.buttons["today.row.0025"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["logging.startWorkout"].waitForExistence(timeout: 5))
        audit(app, "Plan screen")
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
