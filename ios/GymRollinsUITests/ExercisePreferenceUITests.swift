import XCTest

/// Fitbod-style "Recommend more often / less often / Don't recommend again" from Today's row ··· menu and the exercise
/// detail screen; "never" asks first and is undone in Settings → Hidden Exercises; suggestions follow the choices.
final class ExercisePreferenceUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        XCUIApplication.launchReady { $0.buttons["today.start"] }
    }

    private func openRowMenu(_ app: XCUIApplication, _ exerciseId: String) {
        let menu = app.buttons["today.row.menu.\(exerciseId)"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
    }

    /// Menu toggles are exposed as switches/buttons whose value is "1" when checked.
    private func isChecked(_ item: XCUIElement) -> Bool {
        (item.value as? String) == "1" || item.isSelected
    }

    private func menuItem(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testTodayMenuShowsAndTogglesMoreAndLess() {
        let app = launch()
        openRowMenu(app, "0025")
        let more = menuItem(app, "pref.more")
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertFalse(isChecked(more))
        XCTAssertTrue(menuItem(app, "pref.less").exists)
        XCTAssertTrue(menuItem(app, "pref.never").exists)
        more.tap()

        openRowMenu(app, "0025")
        XCTAssertTrue(menuItem(app, "pref.more").waitForExistence(timeout: 5))
        XCTAssertTrue(isChecked(menuItem(app, "pref.more")), "more is checked")
        menuItem(app, "pref.less").tap() // switches to less

        openRowMenu(app, "0025")
        XCTAssertTrue(menuItem(app, "pref.less").waitForExistence(timeout: 5))
        XCTAssertTrue(isChecked(menuItem(app, "pref.less")))
        XCTAssertFalse(isChecked(menuItem(app, "pref.more")))
    }

    func testNeverAsksFirstAndCanBeUndoneInSettings() {
        let app = launch()
        openRowMenu(app, "0025")
        let never = menuItem(app, "pref.never")
        XCTAssertTrue(never.waitForExistence(timeout: 5))
        XCTAssertFalse(isChecked(never))
        never.tap()
        // It asks first; nothing is hidden until confirmed.
        let confirm = app.buttons.matching(identifier: "pref.never.confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        // Still in today's workout: a preference never changes the plan.
        XCTAssertTrue(app.descendants(matching: .any)["today.row.0025"].exists)

        app.buttons["today.settings"].tap()
        let hiddenLink = app.buttons["settings.hiddenExercises"]
        XCTAssertTrue(hiddenLink.waitForExistence(timeout: 5))
        hiddenLink.tap()
        XCTAssertTrue(app.staticTexts["hidden.name.0025"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["hidden.name.0025"].label, "Barbell Bench Press")
        let show = app.buttons["hidden.show.0025"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        show.tap()
        XCTAssertTrue(show.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["hidden.empty"].waitForExistence(timeout: 5))
    }

    func testDetailMenuMorePutsTheExerciseFirstInThePicker() {
        let app = launch()
        app.tabBars.buttons["Library"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("chest dip")
        let row = app.buttons["library.row.0251"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let menu = app.buttons["exercise.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let more = menuItem(app, "pref.more")
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()

        app.tabBars.buttons["Today"].tap()
        let add = app.buttons["today.addExercise"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'picker.row.'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.identifier, "picker.row.0251", "the 'more' exercise leads the suggestions")
    }

    func testNeverIsHiddenFromThePickerButFoundBySearch() {
        let app = launch()
        app.tabBars.buttons["Library"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("3/4 sit-up")
        let row = app.buttons["library.row.0001"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["exercise.menu"].tap()
        let never = menuItem(app, "pref.never")
        XCTAssertTrue(never.waitForExistence(timeout: 5))
        never.tap()
        let confirm = app.buttons.matching(identifier: "pref.never.confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        app.tabBars.buttons["Today"].tap()
        app.buttons["today.addExercise"].tap()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'picker.row.'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertNotEqual(first.identifier, "picker.row.0001", "the first library exercise is hidden")
        let pickerSearch = app.searchFields.firstMatch
        pickerSearch.tap()
        pickerSearch.typeText("3/4 sit-up")
        XCTAssertTrue(app.buttons["picker.row.0001"].waitForExistence(timeout: 5), "search still finds it")
    }
}
