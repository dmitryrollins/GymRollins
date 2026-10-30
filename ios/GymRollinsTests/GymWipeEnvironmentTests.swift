import Foundation
import GymCore
import GymData
import GymSync
import Testing
@testable import GymRollins

/// A rig whose sync backend is signed in (a real `AuthService` fed by `events`, no transport), so sign-out and the
/// account switch run their real paths instead of the disabled backend's no-ops.
@MainActor
private struct SignedInGymRig {
    let rig: GymTestRig
    let events: AsyncStream<AuthEvent>.Continuation
    let userA = UUID()
    let userB = UUID()

    static func make() throws -> SignedInGymRig {
        let (stream, continuation) = AsyncStream<AuthEvent>.makeStream()
        let client = SupabaseConfig(url: URL(string: "http://127.0.0.1:9")!, anonKey: "anon")
            .makeClient(storage: InMemoryAuthStorage())
        let auth = AuthService(client: client, events: stream)
        let rig = try GymTestRig.make { store, now in
            SyncCoordinator(auth: auth, store: store, now: now, makeTransport: { _ in nil })
        }
        return SignedInGymRig(rig: rig, events: continuation)
    }

    var env: AppEnvironment { rig.env }

    /// Workouts plus a gym with a photo: what a signed-in lifter has on the phone.
    func seed() throws -> String {
        let gym = try rig.gymWithPhoto()
        try env.workouts.save(Workout(startedAt: env.now(), endedAt: env.now().addingTimeInterval(60), name: "W"))
        #expect(rig.photoCount() == 2)
        return gym.id.uuidString
    }

    func signIn(as user: UUID) async throws {
        events.yield(.signedIn(userId: user, email: nil))
        try await waitUntil { env.syncStore.ownerUserId == user }
    }

    func expectGymsKept(_ id: String) throws {
        #expect(try env.gyms.gyms().count == 1)
        #expect(try env.gyms.listings(gymId: UUID(uuidString: id)!).count == 1)
        #expect(rig.photoCount() == 2)
        #expect(rig.defaults.string(forKey: AppEnvironment.currentGymKey) == id)
        #expect(env.currentGym?.id.uuidString == id)
    }
}

@MainActor
@Suite struct GymWipeEnvironmentTests {
    private func addGym(_ rig: GymTestRig) throws {
        let gym = try rig.gymWithPhoto()
        #expect(try rig.env.gyms.gym(gym.id) != nil)
        #expect(rig.photoCount() == 2)
    }

    private func expectGymsGone(_ rig: GymTestRig) throws {
        #expect(try rig.env.gyms.gyms().isEmpty)
        #expect(rig.photoCount() == 0)
        #expect(rig.env.currentGym == nil)
        #expect(rig.defaults.object(forKey: AppEnvironment.currentGymKey) == nil)
    }

    @Test func eraseAllRemovesGymsAndPhotos() throws {
        let rig = try GymTestRig.make()
        try addGym(rig)
        try rig.env.eraseAllLocalData()
        try expectGymsGone(rig)
    }

    @Test func deleteAccountRemovesGymsAndPhotos() async throws {
        let rig = try GymTestRig.make()
        try addGym(rig)
        try await rig.env.sync.deleteAccount()
        try expectGymsGone(rig)
    }

    @Test func signOutKeepsGymsPhotosAndTheCurrentGymButRemovesTheWorkouts() async throws {
        let signedIn = try SignedInGymRig.make()
        let id = try signedIn.seed()
        try await signedIn.signIn(as: signedIn.userA)
        #expect(try signedIn.env.workouts.recent(limit: 5).count == 1)

        try await signedIn.env.sync.signOutAndRemoveLocalData()

        #expect(try signedIn.env.workouts.recent(limit: 5).isEmpty)
        try signedIn.expectGymsKept(id)
    }

    @Test func confirmingAnAccountSwitchKeepsGymsPhotosAndTheCurrentGym() async throws {
        let signedIn = try SignedInGymRig.make()
        let id = try signedIn.seed()
        signedIn.env.syncStore.ownerUserId = signedIn.userB
        signedIn.events.yield(.signedIn(userId: signedIn.userA, email: nil))
        try await waitUntil { signedIn.env.sync.accountSwitchPending }
        #expect(try signedIn.env.workouts.recent(limit: 5).count == 1)

        try await signedIn.env.sync.confirmAccountSwitch()

        #expect(!signedIn.env.sync.accountSwitchPending)
        #expect(try signedIn.env.workouts.recent(limit: 5).isEmpty)
        try signedIn.expectGymsKept(id)
    }
}
