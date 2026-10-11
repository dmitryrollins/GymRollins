import Foundation
import Testing
@testable import GymWatchLink

@Suite struct WatchMessagesTests {
    static let start = Date(timeIntervalSince1970: 1_790_000_000.125)

    static func sampleWorkout(rest: Bool = true) -> WatchWorkout {
        WatchWorkout(
            id: UUID(), name: "Push", startedAt: start, pausedSeconds: 30, pausedAt: nil,
            next: WatchNextSet(entryId: UUID(), setId: UUID(), exerciseName: "Barbell Bench Press",
                               setLabel: "Set 3/5", setDetail: "135 lb × 8", canLog: true, weight: 135, reps: 8,
                               grid: WatchLoadGrid(unit: .lb, step: 10, offset: 5)),
            status: "Set 3/5",
            rest: rest ? WatchRest(startedAt: start.addingTimeInterval(600), endsAt: start.addingTimeInterval(720)) : nil,
            hasPrevious: true, hasNext: false, watchRecordsHealth: true)
    }

    @Test func stateRoundTripsThroughTheEnvelope() throws {
        let state = WatchState(sentAt: Self.start, workout: Self.sampleWorkout(),
                               lastEnded: WatchEndedWorkout(workoutId: UUID(), endedAt: Self.start, finished: true,
                                                            watchRecordsHealth: false),
                               today: WatchToday(title: "Push", canStart: true), healthEnabled: true)
        let payload = try WatchEnvelope.encode(state)
        #expect(payload["v"] as? Int == WatchProtocol.version)
        #expect(payload["type"] as? String == "state")
        #expect(try WatchEnvelope.decode(payload) == .state(state))
    }

    @Test(arguments: [
        WatchAction.logSet(workoutId: UUID(), entryId: UUID(), setId: UUID(), weight: 137.5, unit: .lb, reps: 7),
        .extendRest(workoutId: UUID(), entryId: UUID(), restStartedAt: start, seconds: 30),
        .skipRest(workoutId: UUID(), entryId: nil, restStartedAt: start),
        .showExercise(workoutId: UUID(), fromEntryId: UUID(), direction: .previous),
        .startToday,
        .healthClaim(workoutId: UUID()),
        .healthRecorded(workoutId: UUID(), averageHeartRate: 121.5, maxHeartRate: 162),
        .requestState
    ])
    func everyCommandRoundTrips(_ action: WatchAction) throws {
        let command = WatchCommand(id: UUID(), issuedAt: Self.start, action: action)
        let payload = try WatchEnvelope.encode(command)
        #expect(payload["type"] as? String == "command")
        #expect(try WatchEnvelope.decode(payload) == .command(command))
    }

    @Test func payloadsAreWatchConnectivityPropertyListTypes() throws {
        let payload = try WatchEnvelope.encode(WatchCommand(action: .startToday))
        // WCSession only carries property-list values: Int, String, Data.
        #expect(PropertyListSerialization.propertyList(payload, isValidFor: .binary))
    }

    @Test func aNewerProtocolVersionIsRejected() throws {
        var payload = try WatchEnvelope.encode(WatchCommand(action: .requestState))
        payload["v"] = WatchProtocol.version + 1
        #expect(throws: WatchEnvelope.DecodingError.unsupportedVersion(WatchProtocol.version + 1)) {
            try WatchEnvelope.decode(payload)
        }
    }

    @Test func malformedPayloadsAreRejected() {
        #expect(throws: WatchEnvelope.DecodingError.malformed) { try WatchEnvelope.decode([:]) }
        #expect(throws: WatchEnvelope.DecodingError.malformed) {
            try WatchEnvelope.decode(["v": 1, "type": "state", "data": Data("{}".utf8)])
        }
        #expect(throws: WatchEnvelope.DecodingError.malformed) {
            try WatchEnvelope.decode(["v": 1, "type": "gossip", "data": Data()])
        }
    }

    @Test func contentEqualityIgnoresTheSendTime() {
        let a = WatchState(sentAt: Self.start, workout: nil, lastEnded: nil, today: nil, healthEnabled: false)
        let b = WatchState(sentAt: Self.start.addingTimeInterval(5), workout: nil, lastEnded: nil, today: nil,
                           healthEnabled: false)
        #expect(a != b)
        #expect(a.hasSameContent(as: b))
    }

    @Test func actionsNameTheirWorkout() {
        let id = UUID()
        #expect(WatchAction.healthClaim(workoutId: id).workoutId == id)
        #expect(WatchAction.skipRest(workoutId: id, entryId: nil, restStartedAt: Self.start).workoutId == id)
        #expect(WatchAction.startToday.workoutId == nil)
    }
}
