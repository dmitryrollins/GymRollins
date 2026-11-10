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

    private let full = "You've reached the limit of 20,000 weigh-ins on one account, deleted ones included. "
        + "This one stays on this iPhone."
    private let check = "CHECK constraint failed: length(name) BETWEEN 1 AND 40"

    private func failure(_ entity: SyncEntity, _ id: String, _ message: String, code: String? = nil) -> SyncFailure {
        SyncFailure(entity: entity, id: id, clientUpdatedAt: now, message: message, code: code)
    }

    /// At an account limit every refused row has the same words: Account shows one line for them, not hundreds.
    @Test func refusedRowsReadAsOneLinePerKindAndReason() {
        let failures = (0..<300).map { failure(.bodyweight, "w\($0)", full, code: "too_many_body_weights") }
            + [failure(.routines, "r1", check, code: "23514")]
        let lines = SyncStatusText.failureLines(failures)
        #expect(lines == [
            SyncFailureLine(entity: .bodyweight, count: 300, message: full),
            SyncFailureLine(entity: .routines, count: 1, message: check),
        ])
        #expect(lines.map(\.title) == ["Weigh-in \u{00B7} 300", "Routine"])
        #expect(SyncStatusText.failures(failures.count) == "301 items couldn't sync")
        #expect(SyncStatusText.failuresFooter(failures) == "They stay on this iPhone. Editing one tries again.")
    }

    /// VoiceOver reads a line as one element, with the count in words, not the middle dot.
    @Test func aRefusedLineReadsAsOneSentence() {
        let lines = SyncStatusText.failureLines([failure(.bodyweight, "w1", full), failure(.bodyweight, "w2", full),
                                                 failure(.gymListings, "l1", check)])
        #expect(lines.map(\.spokenLabel) == ["2 weigh-ins, \(full)", "Equipment, \(check)"])
        let many = SyncStatusText.failureLines([failure(.gymListings, "l1", check), failure(.gymListings, "l2", check)])
        #expect(many.map(\.spokenLabel) == ["2 equipment listings, \(check)"])
    }

    /// One line per kind of row and reason, in the order the store lists them; the same words on two kinds are
    /// two lines.
    @Test func refusedLinesKeepTheStoresOrder() {
        #expect(SyncStatusText.failureLines([]).isEmpty)
        let shared = SyncStatusText.failureLines([failure(.routines, "r1", check), failure(.customExercises, "c1", check)])
        #expect(shared.map(\.title) == ["Routine", "Custom exercise"])
        let mixed = SyncStatusText.failureLines([
            failure(.routines, "r1", check), failure(.bodyweight, "w1", full), failure(.routines, "r2", check),
            failure(.bodyweight, "w2", check),
        ])
        #expect(mixed == [
            SyncFailureLine(entity: .routines, count: 2, message: check),
            SyncFailureLine(entity: .bodyweight, count: 1, message: full),
            SyncFailureLine(entity: .bodyweight, count: 1, message: check),
        ])
        #expect(Set(mixed.map(\.id)).count == 3)
    }

    /// At an account cap an edit is refused again (deleted rows count, plan 31 decision 4), so the footer doesn't
    /// promise it; any other refusal, or one stored before codes were kept, may pass after an edit.
    @Test func theFooterPromisesARetryOnlyWhenAnEditCanHelp() {
        let capped = [failure(.bodyweight, "w1", full, code: "too_many_body_weights"),
                      failure(.workouts, "k1", "Full", code: "too_many_logged_sets")]
        #expect(SyncStatusText.failuresFooter(capped) == "They stay on this iPhone.")
        let editable = [failure(.workouts, "k2", "Too big", code: "too_many_workout_exercises")]
        #expect(SyncStatusText.failuresFooter(capped + editable)
            == "They stay on this iPhone. Editing one tries again.")
        #expect(SyncStatusText.failuresFooter([failure(.routines, "r1", check)])
            == "They stay on this iPhone. Editing one tries again.")
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
