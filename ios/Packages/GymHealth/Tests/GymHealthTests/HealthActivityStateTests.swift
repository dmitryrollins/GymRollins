import Foundation
import Testing
@testable import GymHealth

/// Plan 39's new state fields: a state saved before them still decodes (a failure would turn Health off and drop the
/// export ledgers), and the switches read as on until turned off.
@Suite struct HealthActivityStateTests {
    @Test func aStateSavedBeforePlan39StillDecodesWithHealthOn() throws {
        let suite = "state-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = #"{"enabled":true,"enabledAt":780000000,"workouts":{"A":"f"},"weighIns":{},"lastImportCount":2,"#
            + #""pendingBodyFat":[],"unmatchedDeletions":[],"awaitingRestore":false}"#
        defaults.set(Data(saved.utf8), forKey: HealthSyncState.key)

        let state = HealthSyncState.load(from: defaults)
        #expect(state.enabled)
        #expect(state.workouts == ["A": "f"])
        #expect(state.readsOutsideWorkouts && state.readsActivityDays)
        #expect(!state.activityPermissionsAsked && !state.activityCardDismissed)
        #expect(state.activityAnchor == nil && state.activityDaysReadAt == nil)
        #expect(state.unmatchedActivityDeletions.isEmpty)
    }

    @Test func theNewFieldsRoundTripAndDefaultsArentStored() throws {
        var state = HealthSyncState()
        state.readsOutsideWorkouts = false
        state.activityPermissionsAsked = true
        state.activityAnchor = Data("7".utf8)
        state.unmatchedActivityDeletions = [UUID()]
        let back = try JSONDecoder().decode(HealthSyncState.self, from: JSONEncoder().encode(state))
        #expect(back == state)
        #expect(!back.readsOutsideWorkouts && back.readsActivityDays && back.activityPermissionsAsked)

        state.readsOutsideWorkouts = true
        state.unmatchedActivityDeletions = []
        #expect(state.readsOutsideWorkoutsStorage == nil && state.unmatchedActivityDeletionsStorage == nil)
    }
}
