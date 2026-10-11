import XCTest

/// Launch and scroll baselines (docs/testing/performance.md). Targets: cold launch < 1.5 s on the iPhone 17 Pro
/// simulator; no scroll hitches > 100 ms on Library and Log with 150 workouts.
///
/// Timing-based and slow, so not part of `scripts/ios-test.sh` / `scripts/test-all.sh` (skipped there); run with
/// `scripts/test-perf.sh`.
@MainActor
final class PerformanceUITests: XCTestCase {
    static let fixedNow = "2026-09-26T09:00:00Z"
    static let largeHistory = ["-seedLargeHistory", "-largeHistoryCount", "150"]

    override func setUp() { continueAfterFailure = false }

    private func options(iterations: Int = 5) -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = iterations
        return options
    }

    /// Cold launch to the first frame with the owner seed + history (every launch rebuilds the in-memory store).
    func testColdLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-fixedNow", Self.fixedNow, "-seedHistory"]
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options()) {
            app.launch()
            app.terminate()
        }
    }

    /// Library's 1,300+ exercise list, flung up and back.
    func testLibraryScroll() {
        let app = XCUIApplication.launchReady(Self.largeHistory)
        app.tabBars.buttons["Library"].tap()
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        measureScroll(list)
    }

    /// Log with 150 workouts (paginated 50 at a time), flung up and back.
    func testLogScroll() {
        let app = XCUIApplication.launchReady(Self.largeHistory)
        app.tabBars.buttons["Log"].tap()
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        measureScroll(app.scrollViews.firstMatch)
    }

    private func measureScroll(_ element: XCUIElement) {
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric, XCTOSSignpostMetric.scrollDraggingMetric],
                options: options()) {
            element.swipeUp(velocity: .fast)
            element.swipeUp(velocity: .fast)
            element.swipeDown(velocity: .fast)
            element.swipeDown(velocity: .fast)
        }
    }
}
