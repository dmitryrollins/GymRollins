import Foundation
import GymData
import GymSync
import SwiftData
import Testing
@testable import GymRollins

/// The launch moves the data to the API it talks to, before any session is restored (spec section 4, "Server move").
@MainActor
@Suite struct ServerMoveLaunchTests {
    let container: ModelContainer
    let suite = "server-move-launch-\(UUID())"
    let defaults: UserDefaults

    init() throws {
        container = try GymStore.container(inMemory: true)
        defaults = UserDefaults(suiteName: suite)!
    }

    private var store: SyncStore { SyncStore(context: container.mainContext, defaults: defaults, now: Date.init) }

    private func launch(_ arguments: [String]) -> SyncCoordinator {
        let options = LaunchOptions(arguments: arguments, environment: ["API_URL": "http://127.0.0.1:9"])
        return SyncCoordinator.make(options: options, store: store, now: Date.init)
    }

    @Test func aLaunchAgainstAnotherAPIMovesTheDataBeforeAnyoneSignsIn() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        store.ownerUserId = UUID()
        store.syncedServer = "http://127.0.0.1:55421"
        let sync = launch(["-uiTesting", "-uiTestingBackend", "local", "-forgetSession"])
        #expect(sync.isAvailable)
        #expect(store.ownerUserId == nil)
        #expect(store.syncedServer == "http://127.0.0.1:9")
    }

    @Test func aHermeticLaunchLeavesTheDataAlone() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = UUID()
        store.ownerUserId = owner
        store.syncedServer = "http://127.0.0.1:55421"
        let sync = launch(["-uiTesting"])
        #expect(!sync.isAvailable)
        #expect(store.ownerUserId == owner)
        #expect(store.syncedServer == "http://127.0.0.1:55421")
    }
}
