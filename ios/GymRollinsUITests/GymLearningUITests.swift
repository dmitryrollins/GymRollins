import XCTest

/// A workout finished at a gym adds what it shows the gym has, and the summary says so (owner, 2026-11-18).
final class GymLearningUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// `-seedGym` makes Home current with kettlebells and a flat bench. The barbell bench press (0025) also needs a
    /// barbell, so Home lists one after; its rack is "a power rack or a bench press station", which a workout can't
    /// tell apart, so the first of them is added (owner, 2026-11-22).
    func testFinishingAtAGymAddsWhatTheWorkoutUsed() {
        let app = XCUIApplication.launchReady(["-seedHistory", "-seedGym"]) { $0.buttons["today.start"] }
        app.startWorkout()
        app.openExercise("0025")
        app.buttons["logging.logAll"].tapCenter()
        app.backToOverview()
        app.buttons["workout.finish"].tapCenter()
        app.buttons["finish.discardEmpty"].tapCenter() // the other exercises are still undone

        let learned = app.descendants(matching: .any)["summary.gymEquipment"]
        XCTAssertTrue(learned.waitForExistence(timeout: 5))
        XCTAssertTrue(learned.label.contains("Added to Home: Barbell and plates, Power or squat rack"), learned.label)
    }
}
