import Foundation
import Testing
@testable import GymRollins

/// The action waiting for a sign-in belongs to the sheet that is open: closing the sheet takes it back, and a
/// sign-in that finishes afterwards runs nothing.
@MainActor
@Suite struct SignInGateTests {
    @Test func signingInRunsTheActionOnce() {
        let gate = SignInGate()
        var ran = 0
        gate.ask(.share) { ran += 1 }
        #expect(gate.isPresented)
        gate.signedIn()
        gate.signedIn()
        #expect(ran == 1)
        #expect(!gate.isPresented)
    }

    @Test func cancellingBeforeTheSignInReturnsRunsNothing() {
        let gate = SignInGate()
        var ran = 0
        gate.ask(.sync) { ran += 1 }
        gate.cancelled()
        gate.signedIn() // the sign-in call finished after the user pressed Cancel
        #expect(ran == 0)
    }

    @Test func aLaterAskIsNotRunByAnEarlierSignIn() {
        let gate = SignInGate()
        var first = 0, second = 0
        gate.ask(.share) { first += 1 }
        gate.cancelled()
        gate.ask(.confirm) { second += 1 }
        gate.signedIn()
        #expect(first == 0 && second == 1)
        #expect(gate.purpose == .confirm)
    }

    @Test func eachEntryPointHasCopyThatIsTrueForIt() {
        let backup = "Signing in also backs up your workouts, routines, weigh-ins and profile to your account. "
            + "Gyms and equipment marked This phone only stay on this phone."
        #expect(SignInPurpose.share.body == "Share this gym's equipment with other people. " + backup)
        #expect(SignInPurpose.confirm.body == "Confirm that this equipment is at the gym, for everyone who trains there. " + backup)
        #expect(SignInPurpose.sync.body == "Sync this to your account so it is there on your other devices. Only you can see it. " + backup)
        #expect(SignInPurpose.report.body == "Report this so it can be checked. " + backup)
        #expect(SignInPurpose.report.title == "Sign in to report")
        #expect(SignInPurpose.sync.title == "Sign in to sync" && SignInPurpose.share.title == "Sign in to share")
    }
}
