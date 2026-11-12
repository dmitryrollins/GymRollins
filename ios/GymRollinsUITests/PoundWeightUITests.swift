import XCTest

/// Weights keep their pound number (plan 38). `-seedKgPlanWeight` plans Push's bench at 20.3 kg with no pound number,
/// as an agent sent 45 lb before (it showed as 44.8 lb); the launch's one-time cleanup makes it 45 lb.
final class PoundWeightUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testAnAgentsKgPlanWeightShowsAsItsPoundNumber() {
        let app = XCUIApplication.launchReady(["-seedKgPlanWeight"]) { $0.buttons["today.start"] }
        let row = app.buttons["today.row.0025"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("45 lb"), row.label)
        XCTAssertFalse(row.label.contains("44.8"), row.label)

        // The exercise screen: 45 lb is the bar, so no warm-ups and set 0 is the first working set.
        row.tap()
        let weight = app.textFields["logging.set.0.weight"]
        XCTAssertTrue(weight.waitForExistence(timeout: 5))
        XCTAssertEqual(weight.value as? String, "45")
        app.buttons["logging.close"].tap()

        // The plan itself, where the stepper shows the stored weight.
        let myPlan = app.buttons["today.myPlan"]
        XCTAssertTrue(myPlan.waitForExistence(timeout: 5))
        myPlan.tap()
        let saved = app.buttons["plan.savedWorkouts"]
        app.scrollToHittable(saved)
        saved.tap()
        let push = app.buttons["plan.routine.Push + Arms"]
        XCTAssertTrue(push.waitForExistence(timeout: 5))
        push.tap()
        // Incline dumbbell press is also planned at 45 lb, so read the bench's own stepper.
        let stepper = app.steppers["edit.weight.0025"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 5))
        XCTAssertEqual(stepper.label, "45 lb (20.4 kg)")
    }

    func testATypedPoundWeightIsTheSameAfterARelaunch() {
        var app = XCUIApplication.launchReady(["-diskStore", "-resetStore"]) { $0.buttons["today.start"] }
        app.startWorkout()
        app.openExercise("0025")
        let first = app.textFields["logging.set.2.weight"] // two warm-ups, then the first working set
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.clearAndType("47.5")
        app.dismissKeyboardIfPresent()
        XCTAssertEqual(first.value as? String, "47.5")
        XCTAssertEqual(app.textFields["logging.set.3.weight"].value as? String, "47.5", "it carries to the next set")
        app.terminate()

        app = XCUIApplication.launchReady(["-diskStore"]) { $0.buttons["today.resume"] }
        app.buttons["today.resume"].tapCenter()
        app.openExercise("0025")
        let reopened = app.textFields["logging.set.2.weight"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertEqual(reopened.value as? String, "47.5")
        XCTAssertEqual(app.textFields["logging.set.3.weight"].value as? String, "47.5")
    }
}
