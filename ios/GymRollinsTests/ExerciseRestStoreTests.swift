import Foundation
import GymCore
import Testing
@testable import GymRollins

/// Each exercise's own rest is kept on this iPhone (UserDefaults), survives a relaunch, and goes with the local data
/// when it is erased or the account is deleted.
@MainActor
@Suite struct ExerciseRestStoreTests {
    private func freshDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ExerciseRestStoreTests.\(UUID())"))
    }

    @Test func aRestRoundTripsThroughUserDefaults() throws {
        let defaults = try freshDefaults()
        let store = ExerciseRestStore(defaults: defaults)
        #expect(store.custom("0025") == nil)
        store.set(210, for: "0025")
        store.set(60, for: "0319")
        #expect(store.custom("0025") == 210)
        let relaunched = ExerciseRestStore(defaults: defaults)
        #expect(relaunched.seconds == ["0025": 210, "0319": 60])
    }

    @Test func nilRemovesTheExercisesRest() throws {
        let defaults = try freshDefaults()
        let store = ExerciseRestStore(defaults: defaults)
        store.set(210, for: "0025")
        store.set(nil, for: "0025")
        #expect(store.custom("0025") == nil)
        #expect(ExerciseRestStore(defaults: defaults).seconds.isEmpty)
    }

    @Test func clearForgetsEveryExercise() throws {
        let defaults = try freshDefaults()
        let store = ExerciseRestStore(defaults: defaults)
        store.set(210, for: "0025")
        store.set(60, for: "0319")
        store.clear()
        #expect(store.seconds.isEmpty)
        #expect(ExerciseRestStore(defaults: defaults).seconds.isEmpty)
    }

    @Test func aStoredValueOutsideTheLimitsIsIgnored() throws {
        let defaults = try freshDefaults()
        defaults.set(["0025": 210, "0319": 5_000, "0070": -1], forKey: ExerciseRestStore.key)
        #expect(ExerciseRestStore(defaults: defaults).seconds == ["0025": 210])
    }

    // MARK: The app's copy

    @Test func choosingTheSuggestionKeepsNone() throws {
        let rig = try GymTestRig.make()
        let env = rig.env
        env.setWorkingRest(210, exerciseId: "0025", defaultSec: 120)
        #expect(env.exerciseRests.custom("0025") == 210)
        #expect(env.workingRest(exerciseId: "0025", defaultSec: 120) == 210)
        env.setWorkingRest(180, exerciseId: "0025", defaultSec: 120) // bench's suggestion
        #expect(env.exerciseRests.custom("0025") == nil)
        #expect(env.workingRest(exerciseId: "0025", defaultSec: 240) == 240, "it follows a later default")
        #expect(env.workingRest(exerciseId: "0319", defaultSec: 120) == 90, "incline fly's suggestion")
    }

    @Test func erasingLocalDataClearsIt() throws {
        let rig = try GymTestRig.make()
        rig.env.exerciseRests.set(210, for: "0025")
        try rig.env.eraseAllLocalData()
        #expect(rig.env.exerciseRests.seconds.isEmpty)
        #expect(ExerciseRestStore(defaults: rig.defaults).seconds.isEmpty)
    }

    @Test func deletingTheAccountClearsIt() async throws {
        let rig = try GymTestRig.make()
        rig.env.exerciseRests.set(210, for: "0025")
        try await rig.env.sync.deleteAccount()
        #expect(rig.env.exerciseRests.seconds.isEmpty)
    }

    @Test func signingOutKeepsIt() async throws {
        let signedIn = try SignedInGymRig.make()
        try await signedIn.signIn(as: signedIn.userA)
        signedIn.env.exerciseRests.set(210, for: "0025")
        try await signedIn.env.sync.signOutAndRemoveLocalData()
        #expect(signedIn.env.exerciseRests.custom("0025") == 210, "like This phone only gyms")
    }

    @Test func aFreshStoreLaunchForgetsAnEarlierRun() throws {
        let defaults = try freshDefaults()
        ExerciseRestStore(defaults: defaults).set(210, for: "0025")
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]), defaults: defaults)
        #expect(env.exerciseRests.seconds.isEmpty, "UI tests share the simulator's defaults")
    }

    @Test func settingsListsTheRestsByName() {
        let rows = ExerciseRestRow.rows(["0319": 60, "0025": 210]) { $0 == "0025" ? "Barbell Bench Press" : "Dumbbell Incline Fly" }
        #expect(rows.map(\.id) == ["0025", "0319"])
        #expect(rows.map(\.seconds) == [210, 60])
    }
}
