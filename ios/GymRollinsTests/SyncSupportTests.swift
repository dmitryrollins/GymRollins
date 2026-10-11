import Foundation
import GymCore
import GymData
import GymSync
import Testing
@testable import GymRollins

@Suite struct AppleNonceTests {
    @Test func sha256MatchesKnownVector() {
        #expect(AppleNonce.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(AppleNonce.sha256("").count == 64)
    }

    @Test func randomNonceHasRequestedLengthAndCharset() throws {
        let nonce = try AppleNonce.random(length: 48)
        #expect(nonce.count == 48)
        #expect(nonce.allSatisfy { AppleNonce.charset.contains($0) })
        #expect(AppleNonce.charset.count == 64) // uniform modulo over bytes
    }

    @Test func randomNoncesDiffer() throws {
        let nonces = try Set((0..<20).map { _ in try AppleNonce.random() })
        #expect(nonces.count == 20)
    }
}

@Suite struct SyncStatusTextTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z")!

    @Test func bannerHiddenWhileIdleOrSyncing() {
        #expect(SyncBannerState.make(.idle) == nil)
        #expect(SyncBannerState.make(.syncing) == nil)
    }

    @Test func bannerForOfflineErrorAndConflicts() {
        #expect(SyncBannerState.make(.offline) == SyncBannerState(kind: .offline,
                                                                    text: "Offline \u{00B7} changes saved on this iPhone"))
        #expect(SyncBannerState.make(.error("boom"))?.kind == .error)
        let one = SyncBannerState.make(.conflicts([UUID()]))
        #expect(one?.text == "1 workout changed on another device \u{00B7} Review")
        #expect(one?.reviewable == true)
        #expect(SyncBannerState.make(.conflicts([UUID(), UUID()]))?.text.hasPrefix("2 workouts changed") == true)
        #expect(SyncBannerState.make(.offline)?.reviewable == false)
    }

    @Test func lastSyncedIsRelative() {
        #expect(SyncStatusText.lastSynced(nil, now: now) == "Never")
        #expect(SyncStatusText.lastSynced(now, now: now) == "Just now")
        #expect(SyncStatusText.lastSynced(now.addingTimeInterval(-59), now: now) == "Just now")
        #expect(SyncStatusText.lastSynced(now.addingTimeInterval(-120), now: now) == "2 min ago")
        #expect(SyncStatusText.lastSynced(now.addingTimeInterval(-3 * 3_600), now: now) == "3 h ago")
        #expect(SyncStatusText.lastSynced(now.addingTimeInterval(10), now: now) == "Just now") // clock skew
    }

    @Test func accountStatusText() {
        #expect(SyncStatusText.status(.idle, pending: 0, lastSyncedAt: nil) == "Not synced yet")
        #expect(SyncStatusText.status(.idle, pending: 0, lastSyncedAt: now) == "Up to date")
        #expect(SyncStatusText.status(.idle, pending: 1, lastSyncedAt: now) == "1 change waiting to sync")
        #expect(SyncStatusText.status(.offline, pending: 0, lastSyncedAt: now) == "Offline")
        #expect(SyncStatusText.status(.offline, pending: 3, lastSyncedAt: now) == "Offline \u{00B7} 3 changes waiting to sync")
        #expect(SyncStatusText.status(.syncing, pending: 0, lastSyncedAt: nil) == "Syncing\u{2026}")
        #expect(SyncStatusText.status(.error("Nope"), pending: 0, lastSyncedAt: nil) == "Nope")
        #expect(SyncStatusText.status(.conflicts([UUID()]), pending: 1, lastSyncedAt: now) == "1 workout needs review")
    }

    @Test func conflictSummary() {
        let start = now
        let workout = Workout(startedAt: start, endedAt: start.addingTimeInterval(600), name: "Push", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 100, reps: 5, done: true),
                                                    WorkoutSet(weightKg: 100, reps: 5, done: true)]),
        ])
        let summary = WorkoutConflictSummary.make(workout, unit: .kg)
        #expect(summary.name == "Push")
        #expect(summary.sets == "2 sets")
        #expect(summary.volume.contains("1000") || summary.volume.contains("1,000"))
    }
}

@Suite struct LaunchOptionsSyncTests {
    @Test func uiTestingIsHermeticByDefault() {
        let options = LaunchOptions(arguments: ["-uiTesting"], environment: [:])
        #expect(options.syncBackend == .disabled)
        #expect(options.simulateOffline == false)
    }

    @Test func localBackendAndOfflineFlag() {
        let options = LaunchOptions(arguments: ["-uiTesting", "-uiTestingBackend", "local"],
                                    environment: ["GYM_SIMULATE_OFFLINE": "1"])
        #expect(options.syncBackend == .uiTestLocal)
        #expect(options.simulateOffline)
    }

    @Test func normalLaunchUsesConfiguredBackend() {
        #expect(LaunchOptions(arguments: [], environment: [:]).syncBackend == .configured)
        #expect(LaunchOptions(arguments: ["-uiTesting", "-seedConflict"], environment: [:]).syncBackend == .seededConflict)
    }

    @Test func noSeedSkipsOwnerSeed() {
        #expect(LaunchOptions(arguments: ["-uiTesting"], environment: [:]).seedOwner)
        #expect(!LaunchOptions(arguments: ["-uiTesting", "-noSeed"], environment: [:]).seedOwner)
    }
}
