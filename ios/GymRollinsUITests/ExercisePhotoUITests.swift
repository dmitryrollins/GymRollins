import XCTest

/// Exercise photos without the network: `-uiTestingPhotos` swaps in locally drawn stand-in photos
/// (`StubPhotoProvider`/`StubPhotoLoader`); plain `-uiTesting` shows the body-part illustration.
final class ExercisePhotoUITests: XCTestCase {
    private let positions: Set<String> = ["Start position", "End position"]

    override func setUp() {
        continueAfterFailure = false
    }

    private func openBenchDetail(_ app: XCUIApplication) {
        app.tabBars.buttons["Library"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("barbell bench press")
        let row = app.buttons["library.row.0025"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
    }

    func testDetailShowsStartAndEndPhotos() {
        let app = XCUIApplication.launchReady(["-uiTestingPhotos"])
        openBenchDetail(app)
        let photo = app.images["exercise.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(positions.contains(photo.label), "labelled \(photo.label)")

        // Tapping flips to the other position (the auto crossfade is off under -uiTesting).
        XCTAssertEqual(photo.label, "Start position")
        let before = photo.label
        photo.tap()
        let flipped = NSPredicate(format: "label != %@", before)
        wait(for: [expectation(for: flipped, evaluatedWith: photo)], timeout: 5)
        XCTAssertTrue(positions.contains(photo.label))
    }

    func testLoggingHeroShowsPhoto() {
        let app = XCUIApplication.launchReady(["-uiTestingPhotos"])
        app.startWorkout()
        app.openExercise("0025")
        let photo = app.images["exercise.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertEqual(photo.label, "Start position")
        // The hero's title/gradient overlay must not swallow the tap-to-flip (the only way with Reduce Motion).
        photo.tap()
        let flipped = NSPredicate(format: "label == %@", "End position")
        wait(for: [expectation(for: flipped, evaluatedWith: photo)], timeout: 5)
    }

    /// Under -uiTestingPhotos the bench press stand-in counts as an AI-generated (own) photo.
    func testAIPhotoShowsBadgeThatExplainsItMayBeWrong() {
        let app = XCUIApplication.launchReady(["-uiTestingPhotos"])
        openBenchDetail(app)
        let badge = app.buttons["exercise.photo.aiBadge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertEqual(badge.label, "AI-generated image. Double-tap for details.")
        badge.tap()
        let alert = app.alerts["AI-generated image"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS 'not an accurate representation'"))
            .firstMatch.exists)
        alert.buttons["OK"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        // The photo itself still flips on tap.
        let photo = app.images["exercise.photo"]
        XCTAssertEqual(photo.label, "Start position")
        photo.tap()
        wait(for: [expectation(for: NSPredicate(format: "label == %@", "End position"), evaluatedWith: photo)],
             timeout: 5)
    }

    func testPlainUITestingShowsTheIllustrationOnly() {
        let app = XCUIApplication.launchReady()
        openBenchDetail(app)
        XCTAssertFalse(app.images["exercise.photo"].waitForExistence(timeout: 2))
    }
}

/// wger photos (Creative Commons, per-photo credit) and other-language names, hermetic: under -uiTestingPhotos the
/// lever seated fly (0596) stands in for a credited wger photo; the names come from the bundled JSON.
final class WgerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func openDetail(_ app: XCUIApplication, search text: String, id: String) {
        app.tabBars.buttons["Library"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(text)
        let row = app.buttons["library.row.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(text) should find \(id)")
        XCTAssertFalse(app.buttons["exercise.photo.credit"].exists, "list thumbnails carry no caption")
        row.tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
    }

    func testDetailShowsTheWgerPhotoCreditAndItsSheet() {
        let app = XCUIApplication.launchReady(["-uiTestingPhotos"])
        openDetail(app, search: "lever seated fly", id: "0596")
        let photo = app.images["exercise.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertEqual(photo.label, "Photo 1 of 2", "wger images aren't labelled as start/end positions")
        XCTAssertFalse(app.buttons["exercise.photo.aiBadge"].exists, "not our AI photo: no AI badge")

        let credit = app.buttons["exercise.photo.credit"]
        XCTAssertTrue(credit.waitForExistence(timeout: 5))
        XCTAssertTrue(credit.label.hasPrefix("Photo: Everkinetic \u{00B7} CC-BY-SA 3"), credit.label)
        credit.tap()
        XCTAssertTrue(app.navigationBars["Photo credit"].waitForExistence(timeout: 5))
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any.containing(NSPredicate(format: "label CONTAINS 'Everkinetic'")).firstMatch.exists)
        XCTAssertTrue(any.containing(NSPredicate(format: "label CONTAINS 'Butterfly'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["photoCredit.license"].exists, "the license links to its text")
        XCTAssertTrue(app.buttons["photoCredit.source"].exists, "the source links to the wger page")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Resized and cropped'"))
            .firstMatch.exists)
        app.buttons["photoCredit.done"].tap()
        XCTAssertTrue(app.navigationBars["Photo credit"].waitForNonExistence(timeout: 5))
    }

    func testFreeExerciseDBPhotoHasNoCredit() {
        let app = XCUIApplication.launchReady(["-uiTestingPhotos"])
        openDetail(app, search: "cable pulldown", id: "0198")
        XCTAssertTrue(app.images["exercise.photo"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["exercise.photo.credit"].exists)
    }

    func testSearchFindsAnExerciseByItsGermanNameAndTheDetailListsOtherNames() {
        let app = XCUIApplication.launchReady()
        openDetail(app, search: "Latzug", id: "0198")
        XCTAssertEqual(app.staticTexts["detail.title"].label, "Cable Pulldown", "the English name stays primary")
        let names = app.descendants(matching: .any)["detail.otherNames"]
        XCTAssertTrue(names.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS 'Latzug'"))
            .firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["detail.otherNames.credit"].exists)
    }
}
