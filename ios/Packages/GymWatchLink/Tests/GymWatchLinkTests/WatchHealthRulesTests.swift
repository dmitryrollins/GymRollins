import Foundation
import Testing
@testable import GymWatchLink

/// Exactly one Health workout per GymRollins workout: the phone exports unless the watch owns it, and the watch only
/// saves when the phone accepted its claim (and early enough that the phone's fallback can't have run).
@Suite struct WatchHealthRulesTests {
    let ended = Date(timeIntervalSince1970: 1_790_000_000)
    let workoutId = UUID()

    @Test func unclaimedWorkoutsAreExportedByThePhone() {
        #expect(WatchHealthRules.phoneDecision(ledger: nil, claimedAt: nil, endedAt: ended, now: ended) == .export)
    }

    @Test func aRecordedByWatchWorkoutIsNeverExportedByThePhone() {
        #expect(WatchHealthRules.phoneDecision(ledger: WatchHealthRules.recordedByWatch, claimedAt: nil, endedAt: ended,
                                               now: ended.addingTimeInterval(86_400 * 30)) == .recordedByWatch)
    }

    @Test func aClaimedWorkoutWaitsForTheWatchThenFallsBack() {
        let claimed = ended.addingTimeInterval(-1_800)
        #expect(WatchHealthRules.phoneDecision(ledger: nil, claimedAt: claimed, endedAt: ended, now: ended)
            == .waitForWatch)
        let justBefore = ended.addingTimeInterval(WatchHealthRules.phoneFallbackDelay - 1)
        #expect(WatchHealthRules.phoneDecision(ledger: nil, claimedAt: claimed, endedAt: ended, now: justBefore)
            == .waitForWatch)
        let after = ended.addingTimeInterval(WatchHealthRules.phoneFallbackDelay)
        #expect(WatchHealthRules.phoneDecision(ledger: nil, claimedAt: claimed, endedAt: ended, now: after)
            == .exportUnlessWatchSaved)
    }

    @Test func theWatchSaveWindowClosesBeforeThePhoneFallback() {
        #expect(WatchHealthRules.watchSaveWindow < WatchHealthRules.phoneFallbackDelay)
    }

    @Test func theWatchSavesOnlyAnAcceptedFinishedWorkoutInTime() {
        let accepted = WatchEndedWorkout(workoutId: workoutId, endedAt: ended, finished: true, watchRecordsHealth: true)
        #expect(WatchHealthRules.watchShouldSave(workoutId: workoutId, ended: accepted, now: ended.addingTimeInterval(60)))
        #expect(!WatchHealthRules.watchShouldSave(workoutId: workoutId, ended: accepted,
                                                  now: ended.addingTimeInterval(WatchHealthRules.watchSaveWindow + 1)))
        let notAccepted = WatchEndedWorkout(workoutId: workoutId, endedAt: ended, finished: true,
                                            watchRecordsHealth: false)
        #expect(!WatchHealthRules.watchShouldSave(workoutId: workoutId, ended: notAccepted, now: ended))
        let discarded = WatchEndedWorkout(workoutId: workoutId, endedAt: ended, finished: false, watchRecordsHealth: true)
        #expect(!WatchHealthRules.watchShouldSave(workoutId: workoutId, ended: discarded, now: ended))
        let other = WatchEndedWorkout(workoutId: UUID(), endedAt: ended, finished: true, watchRecordsHealth: true)
        #expect(!WatchHealthRules.watchShouldSave(workoutId: workoutId, ended: other, now: ended))
        #expect(!WatchHealthRules.watchShouldSave(workoutId: workoutId, ended: nil, now: ended))
    }

    /// Ended at the last set long before Finish was tapped (`IdleFinish`): the save window runs from the tap, so the
    /// watch still saves its session, ending it at the earlier time.
    @Test func theSaveWindowRunsFromFinishNotFromAnEarlierEnd() {
        let finishedAt = ended.addingTimeInterval(2 * 3_600)
        let early = WatchEndedWorkout(workoutId: workoutId, endedAt: ended, finished: true, watchRecordsHealth: true,
                                      finishedAt: finishedAt)
        #expect(WatchHealthRules.watchShouldSave(workoutId: workoutId, ended: early,
                                                 now: finishedAt.addingTimeInterval(60)))
        #expect(!WatchHealthRules.watchShouldSave(workoutId: workoutId, ended: early,
                                                  now: finishedAt.addingTimeInterval(WatchHealthRules.watchSaveWindow + 1)))
    }

    /// A phone build from before `finishedAt` existed still decodes (and falls back to `endedAt`).
    @Test func endedWorkoutWithoutFinishedAtDecodes() throws {
        let old = #"{"workoutId":"\#(workoutId.uuidString)","endedAt":0,"finished":true,"watchRecordsHealth":true}"#
        let decoded = try JSONDecoder().decode(WatchEndedWorkout.self, from: Data(old.utf8))
        #expect(decoded.finishedAt == nil)
    }

    @Test func thePhoneAcceptsAClaimOnlyForTheRunningWorkoutWithHealthOn() {
        #expect(WatchHealthRules.phoneAcceptsClaim(workoutId: workoutId, runningWorkoutId: workoutId, healthEnabled: true))
        #expect(!WatchHealthRules.phoneAcceptsClaim(workoutId: workoutId, runningWorkoutId: workoutId,
                                                    healthEnabled: false))
        #expect(!WatchHealthRules.phoneAcceptsClaim(workoutId: workoutId, runningWorkoutId: UUID(), healthEnabled: true))
        #expect(!WatchHealthRules.phoneAcceptsClaim(workoutId: workoutId, runningWorkoutId: nil, healthEnabled: true))
    }

    @Test func theWatchUsesThePhoneExportersIdentifiers() {
        let id = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        #expect(WatchHealthRules.syncIdentifier(workoutId: id) == "gymrollins.workout.3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        #expect(WatchHealthRules.workoutNameKey == "GymRollinsWorkoutName")
        #expect(WatchHealthRules.exportMarkerKey == "GymRollinsExport")
    }

    @Test func theFallbackLooksForTheWatchsCopyBeforeExporting() {
        let claimed = ended.addingTimeInterval(-1_800)
        let after = ended.addingTimeInterval(WatchHealthRules.phoneFallbackDelay)
        #expect(WatchHealthRules.phoneDecision(ledger: nil, claimedAt: claimed, endedAt: ended, now: after)
            == .exportUnlessWatchSaved)
        // Unclaimed workouts export straight away (the watch never saves those).
        #expect(WatchHealthRules.phoneDecision(ledger: nil, claimedAt: nil, endedAt: ended, now: after) == .export)
        // Exported by the phone already (an edit re-exports it): still look first, the watch's copy may have arrived.
        #expect(WatchHealthRules.phoneDecision(ledger: "fingerprint", claimedAt: claimed, endedAt: ended, now: after)
            == .exportUnlessWatchSaved)
    }

    @Test func copiesAreToldApartByWhoWroteThemNotByHealthKitSource() {
        // A companion watch app's samples can carry the iOS app's source: the writer metadata decides.
        #expect(WatchHealthRules.isWatchRecording(writer: WatchHealthRules.watchWriter, deviceModel: "iPhone"))
        #expect(!WatchHealthRules.isWatchRecording(writer: WatchHealthRules.phoneWriter, deviceModel: "Watch"))
        // Saved before the writer key existed: the recording device decides.
        #expect(WatchHealthRules.isWatchRecording(writer: nil, deviceModel: "Watch"))
        #expect(!WatchHealthRules.isWatchRecording(writer: nil, deviceModel: "iPhone"))
        #expect(!WatchHealthRules.isWatchRecording(writer: nil, deviceModel: nil))
        #expect(WatchHealthRules.writerKey == "GymRollinsWriter")
    }
}
