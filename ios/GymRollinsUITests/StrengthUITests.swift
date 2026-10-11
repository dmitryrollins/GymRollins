import XCTest

/// Strength levels in the Body tab, the method sheet, the sex/birth-year sheet and the lift's history screen.
/// `-seedStrength`: a 35-year-old man at 81 kg with bench 130 lb × 10 (Novice), and a squat and deadlift from
/// before the owner's knee note (paused). Screenshots are attached as "strength-*".
final class StrengthUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "strength-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Scrolls `scroller` up until `target` exists and is hittable (lazy List rows).
    private func scroll(_ scroller: XCUIElement, to target: XCUIElement, attempts: Int = 10) {
        for _ in 0..<attempts where !(target.exists && target.isHittable) { scroller.swipeUp() }
        XCTAssertTrue(target.waitForExistence(timeout: 3), "never scrolled to \(target)")
    }

    private func openBody(_ extra: [String]) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication.launchReady(extra)
        app.tabBars.buttons["Body"].tap()
        return (app, app.collectionViews.firstMatch)
    }

    func testBodyShowsLevelsMethodAndHistory() {
        let (app, list) = openBody(["-seedStrength"])
        let bench = element(app, "body.strength.bench")
        scroll(list, to: element(app, "body.strength.deadlift"))
        XCTAssertTrue(bench.label.hasPrefix("Bench press, Novice, e1RM 173.3 lb"), bench.label)
        XCTAssertTrue(bench.label.hasSuffix("to Intermediate"), bench.label)
        let squat = element(app, "body.strength.squat")
        XCTAssertTrue(squat.label.contains("Paused"), squat.label) // the owner's knee note
        XCTAssertTrue(squat.label.contains("e1RM 262.5 lb"), squat.label) // 225 lb x 5, numbers stay visible
        XCTAssertFalse(element(app, "body.strength.missing").exists)
        screenshot(app, "body-card")

        element(app, "body.strength.info").tap()
        let inputs = element(app, "strength.method.inputs")
        XCTAssertTrue(inputs.waitForExistence(timeout: 5))
        XCTAssertEqual(inputs.label, "Male, 35 \u{00B7} 178.6 lb")
        XCTAssertTrue(element(app, "strength.method.thresholds.bench").exists)
        screenshot(app, "method-sheet")
        let source = element(app, "strength.method.source")
        scroll(app.scrollViews.firstMatch, to: source)
        XCTAssertTrue(source.label.contains("OpenPowerlifting"), source.label)
        app.buttons["strength.method.done"].tap()
        XCTAssertTrue(inputs.waitForNonExistence(timeout: 3))

        bench.tap()
        let history = element(app, "history.strength")
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertTrue(history.label.contains("Novice"), history.label)
        screenshot(app, "history")
    }

    func testMissingProfileAsksForSexAndBirthYearThenShowsLevels() {
        let (app, list) = openBody(["-seedHistory", "-seedBodyweight"])
        let missing = element(app, "body.strength.missing")
        scroll(list, to: missing)
        XCTAssertTrue(missing.label.hasPrefix("Add your sex and birth year"), missing.label)
        let bench = element(app, "body.strength.bench")
        XCTAssertTrue(bench.label.hasPrefix("Bench press, e1RM 173.3 lb"), bench.label) // no level yet
        screenshot(app, "empty-profile")

        element(app, "body.strength.addProfile").tap()
        let save = app.buttons["strength.profile.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@",
                                                             "Used only to compare your lifts")).firstMatch.exists)
        app.segmentedControls["strength.profile.sex"].buttons["Male"].tap()
        screenshot(app, "profile-sheet")
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))

        scroll(list, to: bench)
        XCTAssertFalse(element(app, "body.strength.missing").exists)
        let levelled = NSPredicate(format: "label BEGINSWITH %@", "Bench press, Novice, ")
        let updated = XCTNSPredicateExpectation(predicate: levelled, object: bench)
        XCTAssertEqual(XCTWaiter().wait(for: [updated], timeout: 5), .completed, bench.label)
    }

    func testNoHistoryNoWeighInEmptyStates() {
        let (app, list) = openBody([])
        let missing = element(app, "body.strength.missing")
        scroll(list, to: element(app, "body.strength.deadlift"))
        XCTAssertTrue(missing.exists)
        let bench = element(app, "body.strength.bench")
        XCTAssertEqual(bench.label, "Bench press, No sets in the last 12 months")
        XCTAssertTrue(element(app, "body.strength.squat").label.contains("Paused"))
        screenshot(app, "empty-history")
    }
}
