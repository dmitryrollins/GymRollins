import XCTest

/// Today's "Build workout": the sheet, the result, Start, and the gym marks on Today's rows. `-seedGym` gives "Home":
/// kettlebells (20 and 24 kg) and a flat bench, with the seeded Push + Arms routine on the default (Saturday) date.
final class BuildWorkoutUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = ["-seedGym"]) -> XCUIApplication {
        XCUIApplication.launchReady(extra) { $0.buttons["today.gymChip"] }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func buildRows(_ app: XCUIApplication) -> [String] {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'build.row.'"))
            .allElementsBoundByIndex.map { $0.identifier }
    }

    /// The sheet remembers the last chips and length, so set every chip to what the test wants.
    private func choose(_ app: XCUIApplication, chips: [String], minutes: Int) {
        for chip in ["chest", "back", "shoulders", "arms", "legs", "core"] {
            let button = app.buttons["build.chip.\(chip)"]
            if button.isSelected != chips.contains(chip) { button.tap() }
        }
        app.buttons["build.length.\(minutes)"].tap()
    }

    /// Opens the sheet from Today, picks the chips and the length, and taps Build.
    private func build(_ app: XCUIApplication, chips: [String], minutes: Int, file: StaticString = #filePath,
                       line: UInt = #line) {
        app.buttons["today.build"].tapCenter()
        XCTAssertTrue(app.buttons["build.go"].waitForExistence(timeout: 5), "the Build sheet didn't open",
                      file: file, line: line)
        choose(app, chips: chips, minutes: minutes)
        app.buttons["build.go"].tapCenter()
        XCTAssertTrue(element(app, "build.title").waitForExistence(timeout: 10), "the result didn't open",
                      file: file, line: line)
    }

    func testBuildAtHomeShowsBannerAndStarts() {
        let app = launch()
        app.buttons["today.build"].tapCenter()
        let go = app.buttons["build.go"]
        XCTAssertTrue(go.waitForExistence(timeout: 5))
        choose(app, chips: [], minutes: 45)
        XCTAssertFalse(go.isEnabled, "Build needs a muscle")
        XCTAssertEqual(element(app, "build.gymLine").label, "at Home \u{00B7} 2 items")
        choose(app, chips: ["back"], minutes: 60)
        XCTAssertTrue(app.buttons["build.chip.back"].isSelected)
        XCTAssertTrue(app.buttons["build.length.60"].isSelected)
        XCTAssertTrue(go.isEnabled)
        go.tapCenter()

        XCTAssertTrue(element(app, "build.title").waitForExistence(timeout: 10))
        XCTAssertEqual(element(app, "build.title").label, "Back")
        XCTAssertEqual(element(app, "build.subtitle").label, "Home \u{00B7} 6 exercises \u{00B7} ~60 min")
        XCTAssertEqual(element(app, "build.thin").label,
                       "Only 1 Back item catalogued at Home so far. Add a photo to unlock more variety.")
        XCTAssertTrue(app.buttons["build.addEquipment"].exists)
        XCTAssertTrue(element(app, "build.row.1352").label.contains("no equipment"), "the fill says so")
        XCTAssertGreaterThan(buildRows(app).count, 3)

        app.buttons["build.start"].tapCenter()
        XCTAssertTrue(app.staticTexts["workout.clock"].waitForExistence(timeout: 10), "the workout opened")
        XCTAssertFalse(app.buttons["build.go"].exists, "the sheet is gone")
    }

    func testBuildWithNoGymOpensThePickerFirst() {
        let app = launch([])
        app.buttons["today.build"].tapCenter()
        XCTAssertTrue(app.buttons["gymPicker.close"].waitForExistence(timeout: 5), "no gym: the picker opens")
        XCTAssertFalse(app.buttons["build.go"].exists)
        app.buttons["gymPicker.addPrivate"].tap()
        let name = app.textFields["privateGym.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Garage")
        app.buttons["privateGym.save"].tap()
        let row = app.buttons["gymPicker.gym.Garage"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["build.go"].waitForExistence(timeout: 10), "choosing a gym continues to Build")
        XCTAssertEqual(element(app, "build.gymLine").label, "at Garage \u{00B7} 0 items")
    }

    func testRebuildChangesTheList() {
        let app = launch()
        build(app, chips: ["arms"], minutes: 45)
        let first = buildRows(app)
        XCTAssertEqual(first.count, 4)
        app.buttons["build.rebuild"].tapCenter()
        let changed = NSPredicate { _, _ in self.buildRows(app) != first }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 5),
                       .completed, "Rebuild shows other exercises")
        let second = buildRows(app)
        XCTAssertTrue(Set(first).isDisjoint(with: second), "none of them repeat while the gym has more")
    }

    func testSwappedBadgeOnToday() {
        let app = launch()
        let row = element(app, "today.row.swapped.3294")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("SWAPPED"), row.label)
        XCTAssertTrue(row.label.contains("Barbell Bench Press"), "the note names what it replaces: \(row.label)")
        let note = element(app, "today.gymNote")
        XCTAssertTrue(note.exists)
        XCTAssertTrue(note.label.hasSuffix("swapped for this gym. Your plan isn't changed."), note.label)
    }

    func testUsePlannedAnyway() {
        let app = launch()
        XCTAssertTrue(element(app, "today.row.swapped.3294").waitForExistence(timeout: 5))
        app.buttons["today.row.menu.3294"].tap()
        let use = app.buttons["today.menu.usePlanned"]
        XCTAssertTrue(use.waitForExistence(timeout: 5))
        XCTAssertEqual(use.label, "Use Barbell Bench Press anyway")
        use.tap()
        XCTAssertTrue(element(app, "today.row.0025").waitForExistence(timeout: 5), "the planned exercise is back")
        XCTAssertFalse(element(app, "today.row.swapped.3294").exists)
        XCTAssertFalse(element(app, "today.row.swapped.0025").exists, "and the gym leaves it alone")
    }

    /// The two-button bottom bar: both meet 44 pt, and Start still starts.
    func testBottomBarButtonsAreBigEnoughAndStartStillWorks() {
        let app = launch()
        let build = app.buttons["today.build"]
        let start = app.buttons["today.start"]
        XCTAssertTrue(build.waitForExistence(timeout: 5))
        XCTAssertTrue(start.exists)
        XCTAssertGreaterThanOrEqual(build.frame.height, 44)
        XCTAssertGreaterThanOrEqual(build.frame.width, 44)
        XCTAssertGreaterThanOrEqual(start.frame.height, 44)
        app.startWorkout()
    }
}
