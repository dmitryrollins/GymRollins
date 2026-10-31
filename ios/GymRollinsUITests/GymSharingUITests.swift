import XCTest

/// Sharing from the gym screens, with `-fakeGymCatalog`: "Iron Works Gym" is the current gym, the server has a lat
/// pulldown (3 confirms, a photo), a cable station and a row only a newer app can read, and the phone has a flat bench
/// (only here), a barbell whose share failed, and a cable station waiting for a choice. Nobody is signed in, so every
/// share, confirm or retry stops at the sign-in sheet, and cancelling it must change nothing.
final class GymSharingUITests: XCTestCase {
    private let latPulldownId = "00000000-0000-4000-8000-0000000000B1"
    private let cableId = "00000000-0000-4000-8000-0000000000B2"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        XCUIApplication.launchReady(["-fakeGymCatalog"] + extra) { $0.buttons["today.gymChip"] }
    }

    private func openEquipment(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["today.gymChip"].tap()
        let current = app.buttons["gymPicker.currentEquipment"]
        XCTAssertTrue(current.waitForExistence(timeout: 5), "picker didn't open", file: file, line: line)
        current.tap()
        XCTAssertTrue(app.buttons["gymEquipment.add"].waitForExistence(timeout: 5), "equipment didn't open",
                      file: file, line: line)
    }

    private func text(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func waitForLabel(_ element: XCUIElement, contains part: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", part)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    private let backupCopy = "Signing in also backs up your workouts, routines, weigh-ins and profile to your account. "
        + "Gyms and equipment marked This phone only stay on this phone."

    /// The sign-in sheet opened with its copy; cancelling closes it.
    private func cancelSignIn(_ app: XCUIApplication, title expectedTitle: String = "Sign in to share",
                              intro: String = "Share this gym's equipment with other people. ",
                              file: StaticString = #filePath, line: UInt = #line) {
        let title = text(app, "signInForSharing.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the sign-in sheet opens", file: file, line: line)
        XCTAssertEqual(title.label, expectedTitle, file: file, line: line)
        XCTAssertEqual(text(app, "signInForSharing.body").label, intro + backupCopy, file: file, line: line)
        app.buttons["signInForSharing.cancel"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "the sheet closes", file: file, line: line)
    }

    private func openTile(_ app: XCUIApplication, _ kind: String, containing part: String? = nil) {
        let tiles = app.buttons.matching(identifier: "gymEquipment.listing.\(kind)")
        let tile = part.map { tiles.matching(NSPredicate(format: "label CONTAINS %@", $0)).firstMatch } ?? tiles.firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "no \(kind) tile")
        tile.tap()
        XCTAssertTrue(text(app, "listing.shareStatus").waitForExistence(timeout: 5), "detail didn't open")
    }

    func testBrowsingWithNoAccountShowsSharedEquipment() {
        let app = launch()
        openEquipment(app)
        let pulldown = app.buttons["gymEquipment.listing.lat-pulldown"]
        XCTAssertTrue(pulldown.waitForExistence(timeout: 15), "the gym's shared equipment shows without an account")
        XCTAssertTrue(pulldown.label.contains("\u{2713} 3"), "with its confirm count: \(pulldown.label)")
        let newer = app.buttons["gymEquipment.listing.leg-press"]
        for _ in 0..<4 where !newer.exists { app.swipeUp() } // the tiles below the fold aren't built yet
        XCTAssertTrue(newer.waitForExistence(timeout: 5))
        XCTAssertTrue(newer.label.contains("Update the app to use this item"), "a row it can't read says so")
        XCTAssertEqual(app.staticTexts["gymEquipment.subtitle"].label, "12 Main St \u{00B7} 6 items")
        XCTAssertFalse(text(app, "signInForSharing.title").exists, "browsing never meets a login wall")
        for _ in 0..<4 where !pulldown.isHittable { app.swipeDown() } // the swipes above can take it off screen
        pulldown.tap()
        XCTAssertTrue(app.buttons["listing.confirm"].waitForExistence(timeout: 5), "someone else's can be confirmed")
        XCTAssertFalse(app.buttons["listing.delete"].exists, "someone else's can't be removed")
        XCTAssertFalse(app.buttons["listing.save"].exists, "or edited")
    }

    func testAListingWithoutAPhotoBorrowsTheCataloguePhoto() {
        let app = launch(["-gymPhotoFixture"])
        openEquipment(app)
        let tile = app.buttons["gymEquipment.listing.flat-bench"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(tile, contains: "Other gym"), "the tile borrows another gym's photo: \(tile.label)")
        tile.tap()
        XCTAssertTrue(text(app, "listing.catalogPhoto").waitForExistence(timeout: 10), "the capsule shows")
        XCTAssertTrue(text(app, "listing.catalogPhotoNote").exists)
        XCTAssertEqual(text(app, "listing.catalogPhotoNote").label,
                       "Photo from another gym. Add yours to show the real one here.")
        let add = app.buttons["listing.addPhoto"]
        XCTAssertTrue(add.exists, "the user can still add their own")
        add.tap()
        XCTAssertTrue(add.waitForNonExistence(timeout: 30), "the photo was cleaned and attached")
        XCTAssertTrue(text(app, "listing.catalogPhoto").waitForNonExistence(timeout: 5), "theirs replaces the borrowed one")
        XCTAssertTrue(text(app, "listing.catalogPhotoNote").waitForNonExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        let back = app.buttons["gymEquipment.listing.flat-bench"]
        XCTAssertTrue(app.buttons["gymEquipment.listing.lat-pulldown"].waitForExistence(timeout: 10), "the screen loaded")
        XCTAssertFalse(back.label.contains("Other gym"), "the tile shows their photo: \(back.label)")
        back.tap()
        XCTAssertTrue(app.buttons["listing.save"].waitForExistence(timeout: 5), "reopened")
        XCTAssertFalse(text(app, "listing.catalogPhoto").exists, "the borrowed photo doesn't come back")
        XCTAssertFalse(app.buttons["listing.addPhoto"].exists, "it has its own photo now")
    }

    func testShareAsksForSignIn() {
        let app = launch()
        openEquipment(app)
        openTile(app, "flat-bench")
        XCTAssertEqual(text(app, "listing.shareStatus").label, "Only me")
        app.buttons["listing.share"].tap()
        cancelSignIn(app)
        XCTAssertEqual(text(app, "listing.shareStatus").label, "Only me", "cancelling queued nothing")
        XCTAssertTrue(app.buttons["listing.share"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        let tile = app.buttons["gymEquipment.listing.flat-bench"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertTrue(tile.label.contains("Only me"), tile.label)
    }

    func testConfirmAsksForSignIn() {
        let app = launch()
        openEquipment(app)
        openTile(app, "lat-pulldown")
        app.buttons["listing.confirm"].tap()
        cancelSignIn(app, intro: "Confirm that this equipment is at the gym, for everyone who trains there. ")
        XCTAssertTrue(app.buttons["listing.confirm"].exists, "cancelling confirmed nothing")
        XCTAssertNotEqual(text(app, "listing.shareStatus").label, "You confirmed this")
    }

    func testDuplicatesShowTheExistingListings() {
        let app = launch(["-gymPhotoFixture"])
        openEquipment(app)
        XCTAssertTrue(app.buttons["gymEquipment.listing.lat-pulldown"].waitForExistence(timeout: 15), "cached first")
        app.buttons["gymEquipment.add"].tap()
        app.buttons["addEquipment.skip"].tapWhenHittable()
        let field = app.textFields["addEquipment.kindSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText("lat")
        app.buttons["addEquipment.kind.lat-pulldown"].tapCenter()
        let confirm = app.buttons["add.confirm.\(latPulldownId)"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "someone else's listing comes first")
        XCTAssertEqual(confirm.label, "Yes, that's it (+1 confirm)")
        XCTAssertTrue(app.staticTexts["\u{2713} 3"].exists, "with its confirm count")
        XCTAssertTrue(app.buttons["addEquipment.generic"].exists && app.buttons["addEquipment.different"].exists)
        confirm.tapCenter()
        cancelSignIn(app, intro: "Confirm that this equipment is at the gym, for everyone who trains there. ")
        XCTAssertTrue(confirm.exists, "cancelling stays on the list")
        app.buttons["addEquipment.back"].tap()
        let again = app.textFields["addEquipment.kindSearch"]
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        again.tap()
        again.typeText("flat")
        app.buttons["addEquipment.kind.flat-bench"].tapCenter()
        let own = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'add.alreadyAdded.'")).firstMatch
        XCTAssertTrue(own.waitForExistence(timeout: 5), "mine says Already added")
        XCTAssertEqual(own.label, "Already added")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'add.confirm.'")).firstMatch.exists)
    }

    func testAFailedShareOffersRetry() {
        let app = launch()
        openEquipment(app)
        let tile = app.buttons["gymEquipment.listing.barbell"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertTrue(tile.label.contains("Couldn't upload"), tile.label)
        tile.tap()
        XCTAssertEqual(text(app, "listing.shareStatus").label, "Couldn't upload")
        XCTAssertEqual(text(app, "listing.shareReason").label, "Couldn't share this one. Try again later.")
        app.buttons["listing.retry"].tap()
        cancelSignIn(app)
        XCTAssertTrue(app.buttons["listing.retry"].exists, "cancelling retried nothing")
        XCTAssertEqual(text(app, "listing.shareStatus").label, "Couldn't upload")
    }

    func testAListingWaitingForAChoiceShowsTheExistingOne() {
        let app = launch()
        openEquipment(app)
        openTile(app, "cable-station", containing: "Needs a choice")
        XCTAssertEqual(text(app, "listing.shareStatus").label, "This gym may already have it")
        let keep = app.buttons["listing.keepExisting.\(cableId)"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        XCTAssertEqual(keep.label, "Yes, that's it (+1 confirm)")
        let anyway = app.buttons["listing.shareAnyway"]
        XCTAssertEqual(anyway.label, "No, it's a different one")
        anyway.tapCenter()
        cancelSignIn(app)
        XCTAssertTrue(keep.exists && anyway.exists, "cancelling chose nothing")
    }

    func testSyncingAPrivateGymAsksForSignIn() {
        let app = launch()
        app.buttons["today.gymChip"].tap()
        app.buttons["gymPicker.addPrivate"].tap()
        let name = app.textFields["privateGym.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Garage")
        app.buttons["privateGym.save"].tap()
        let row = app.buttons["gymPicker.gym.Garage"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Only me"), row.label)
        row.press(forDuration: 1.2)
        let sync = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'picker.sync.'")).firstMatch
        XCTAssertTrue(sync.waitForExistence(timeout: 5), "the gym's menu offers Sync to my account")
        sync.tap()
        XCTAssertEqual(text(app, "picker.sync.title").label, "Sync Garage?")
        XCTAssertEqual(text(app, "picker.sync.body").label, "The gym goes to your account. Only you can see it.")
        XCTAssertFalse(text(app, "signInForSharing.title").exists, "it asks before it asks for a sign-in")
        app.buttons["picker.sync.cancel"].tap()
        XCTAssertTrue(text(app, "picker.sync.title").waitForNonExistence(timeout: 5))
        XCTAssertFalse(text(app, "signInForSharing.title").exists, "cancelling the question uploads nothing")
        row.press(forDuration: 1.2)
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
        sync.tap()
        app.buttons["picker.sync.confirm"].tap()
        cancelSignIn(app, title: "Sign in to sync",
                     intro: "Sync this to your account so it is there on your other devices. Only you can see it. ")
        XCTAssertTrue(app.buttons["gymPicker.gym.Garage"].label.contains("Only me"), "cancelling synced nothing")
    }

    func testAShareThatNeverWentUpCanBeDeleted() {
        let app = launch()
        openEquipment(app)
        let tile = app.buttons["gymEquipment.listing.barbell"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()
        XCTAssertEqual(text(app, "listing.shareStatus").label, "Couldn't upload")
        app.buttons["listing.delete"].tap()
        XCTAssertEqual(text(app, "listing.delete.message").label,
                       "It and its photo will be deleted from this phone and won't be shared.")
        app.buttons["listing.delete.confirm"].tap()
        XCTAssertTrue(app.buttons["gymEquipment.add"].waitForExistence(timeout: 5), "back on the equipment screen")
        XCTAssertTrue(tile.waitForNonExistence(timeout: 5), "the failed share is gone")
    }

    /// Opens the report sheet from a shared listing's menu.
    private func openReportSheet(_ app: XCUIApplication) {
        let menu = app.buttons["listing.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "someone else's listing has a menu")
        menu.tap()
        let report = app.buttons["listing.report"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        report.tap()
        XCTAssertTrue(app.buttons["report.send"].waitForExistence(timeout: 5), "the report sheet opens")
    }

    func testReportAsksForSignInFirstAndCancellingReportsNothing() {
        let app = launch()
        openEquipment(app)
        openTile(app, "lat-pulldown")
        openReportSheet(app)
        app.buttons["report.send"].tap()
        XCTAssertEqual(text(app, "report.error").label, "Pick what's wrong first.", "a reason comes first")
        app.buttons["report.reason.spam"].tap()
        app.buttons["report.send"].tap()
        cancelSignIn(app, title: "Sign in to report", intro: "Report this so it can be checked. ")
        XCTAssertFalse(text(app, "report.thanks").exists, "nothing was sent")
        app.buttons["report.cancel"].tap()
        XCTAssertTrue(text(app, "listing.shareStatus").waitForExistence(timeout: 5), "the listing is still there")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["gymEquipment.listing.lat-pulldown"].waitForExistence(timeout: 5))
    }

    func testReportingHidesTheListing() {
        let app = launch(["-fakeSignedIn", "-fakeGymCatalogGrows"])
        openEquipment(app)
        let canary = app.buttons["gymEquipment.listing.seated-row-machine"]
        XCTAssertTrue(app.buttons["gymEquipment.listing.cable-station"].waitForExistence(timeout: 15))
        XCTAssertFalse(canary.exists, "the fake adds a row machine from its second read on")
        openTile(app, "lat-pulldown")
        openReportSheet(app)
        app.buttons["report.reason.wrong-info"].tap()
        app.buttons["report.send"].tap()
        XCTAssertEqual(text(app, "report.thanks").label, "Thanks. We'll take a look.")
        app.buttons["report.done"].tap()
        XCTAssertTrue(app.buttons["gymEquipment.add"].waitForExistence(timeout: 5), "back on the equipment screen")
        XCTAssertTrue(app.buttons["gymEquipment.listing.lat-pulldown"].waitForNonExistence(timeout: 5),
                      "the reported listing is gone")
        XCTAssertTrue(app.buttons["gymEquipment.listing.cable-station"].exists, "the others stay")
        // The server still returns it; a refresh must not bring it back. The row machine only appears once the refresh
        // has run and been applied, so waiting for it is what makes the check below mean something.
        app.swipeDown()
        XCTAssertTrue(canary.waitForExistence(timeout: 15), "the refresh ran")
        XCTAssertFalse(app.buttons["gymEquipment.listing.lat-pulldown"].exists)
    }

    func testBlockingSignedOutAsksForSignInInItsOwnWords() {
        let app = launch()
        openEquipment(app)
        openTile(app, "lat-pulldown")
        app.buttons["listing.menu"].tap()
        app.buttons["listing.block"].tap()
        app.buttons["listing.block.confirm"].tap()
        cancelSignIn(app, title: "Sign in to hide", intro: "Hide what this person shares. ")
        XCTAssertTrue(text(app, "listing.shareStatus").waitForExistence(timeout: 5), "the listing is still there")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["gymEquipment.listing.lat-pulldown"].waitForExistence(timeout: 5))
    }

    func testBlockingAnAuthorAsksFirstAndHidesTheListing() {
        let app = launch(["-fakeSignedIn"])
        openEquipment(app)
        openTile(app, "lat-pulldown")
        app.buttons["listing.menu"].tap()
        app.buttons["listing.block"].tap()
        XCTAssertTrue(text(app, "listing.block.message").waitForExistence(timeout: 5))
        app.buttons["listing.block.cancel"].tap()
        XCTAssertTrue(text(app, "listing.block.message").waitForNonExistence(timeout: 5))
        app.buttons["listing.menu"].tap()
        app.buttons["listing.block"].tap()
        app.buttons["listing.block.confirm"].tap()
        XCTAssertTrue(app.buttons["gymEquipment.add"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["gymEquipment.listing.lat-pulldown"].waitForNonExistence(timeout: 5))
    }

    func testAGymCanBeReportedFromItsEquipmentScreen() {
        let app = launch(["-fakeSignedIn"])
        openEquipment(app)
        XCTAssertTrue(app.buttons["gymEquipment.listing.lat-pulldown"].waitForExistence(timeout: 15))
        app.buttons["gymEquipment.menu"].tap()
        app.buttons["gym.report"].tap()
        XCTAssertTrue(app.buttons["report.send"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["report.reason.inappropriate-photo"].exists, "a gym has no photo to report")
        app.buttons["report.reason.not-here-anymore"].tap()
        app.buttons["report.send"].tap()
        XCTAssertTrue(text(app, "report.thanks").waitForExistence(timeout: 5))
        app.buttons["report.done"].tap()
        XCTAssertTrue(app.buttons["gymEquipment.listing.lat-pulldown"].waitForExistence(timeout: 5),
                      "reporting a gym hides nothing")
    }

    func testReportingABorrowedPhotoRemovesItAndKeepsTheListing() {
        let app = launch(["-fakeSignedIn", "-gymPhotoFixture"])
        openEquipment(app)
        openTile(app, "flat-bench")
        XCTAssertTrue(text(app, "listing.catalogPhoto").waitForExistence(timeout: 10), "it borrows a photo")
        app.buttons["listing.menu"].tap()
        app.buttons["listing.reportCatalogPhoto"].tap()
        XCTAssertTrue(app.buttons["report.send"].waitForExistence(timeout: 5))
        let reasons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'report.reason.'")).allElementsBoundByIndex
        XCTAssertEqual(reasons.first?.identifier, "report.reason.inappropriate-photo", "the photo reasons lead")
        app.buttons["report.reason.inappropriate-photo"].tap()
        app.buttons["report.send"].tap()
        XCTAssertTrue(text(app, "report.thanks").waitForExistence(timeout: 5))
        app.buttons["report.done"].tap()
        XCTAssertTrue(text(app, "listing.shareStatus").waitForExistence(timeout: 5), "the listing stays")
        XCTAssertTrue(text(app, "listing.catalogPhoto").waitForNonExistence(timeout: 5), "the picture goes")
        XCTAssertFalse(app.buttons["listing.menu"].exists, "the device listing has nothing left to report")
    }
}
