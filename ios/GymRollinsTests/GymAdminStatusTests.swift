import Foundation
import GymData
import Testing
@testable import GymRollins

@MainActor
@Suite struct GymAdminStatusTests {
    private let userA = UUID()
    private let userB = UUID()

    @Test func theAnswerIsAskedOncePerSignIn() async {
        let status = GymAdminStatus()
        var asked = 0
        for _ in 0..<3 { await status.refresh(userId: userA) { asked += 1; return true } }
        #expect(status.isAdmin)
        #expect(asked == 1)
    }

    @Test func anotherAccountIsAskedAgainAndDoesNotInheritTheAnswer() async {
        let status = GymAdminStatus()
        await status.refresh(userId: userA) { true }
        await status.refresh(userId: userB) { false }
        #expect(!status.isAdmin)
    }

    @Test func signingOutForgetsTheAnswerSoTheNextSignInAsksAgain() async {
        let status = GymAdminStatus()
        var asked = 0
        await status.refresh(userId: userA) { asked += 1; return true }
        status.reset()
        #expect(!status.isAdmin)
        await status.refresh(userId: userA) { asked += 1; return true }
        #expect(asked == 2)
    }

    @Test func aSignedOutPhoneNeverAsks() async {
        let status = GymAdminStatus()
        await status.refresh(userId: userA) { true }
        var asked = 0
        await status.refresh(userId: nil) { asked += 1; return true }
        #expect(asked == 0)
        #expect(!status.isAdmin)
    }

    @Test func aFailedCheckHidesTheRowAndTriesAgainNextTime() async {
        let status = GymAdminStatus()
        await status.refresh(userId: userA) { throw GymCatalogError.offline }
        #expect(!status.isAdmin)
        await status.refresh(userId: userA) { true }
        #expect(status.isAdmin)
    }

    @Test func anAnswerThatArrivesAfterTheSessionEndedIsIgnored() async {
        let status = GymAdminStatus()
        let gate = Gate()
        let pending = Task { await status.refresh(userId: userA) { await gate.wait(); return true } }
        await gate.started()
        status.reset()
        await gate.open()
        await pending.value
        #expect(!status.isAdmin)
    }

    @Test func theEnvironmentForgetsWhenTheSessionEndsAndAsksNothingSignedOut() async throws {
        let rig = try GymTestRig.make()
        let stub = StubCatalogTransport()
        rig.env.gymSharing = GymSharing(
            repository: rig.env.gyms, transport: stub, knownKinds: [],
            photos: GymPhotoCache(store: rig.photos) { _, _ in Data() }, photoData: { _ in nil }, now: rig.env.now)
        rig.env.wireGymSharing()

        await rig.env.refreshGymAdmin()
        #expect(stub.calls.isEmpty, "signed out: no network call")

        await rig.env.gymAdmin.refresh(userId: userA) { true }
        #expect(rig.env.gymAdmin.isAdmin)
        rig.env.sync.onSessionEnding()
        #expect(!rig.env.gymAdmin.isAdmin)
        await rig.env.sync.onWillSignOut()
        #expect(!rig.env.gymAdmin.isAdmin)
    }
}

/// Parks a check until the test lets it finish.
private actor Gate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var didStart = false

    func wait() async {
        didStart = true
        startedWaiter?.resume()
        startedWaiter = nil
        if opened { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func started() async {
        if didStart { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func open() {
        opened = true
        waiting?.resume()
        waiting = nil
    }
}
