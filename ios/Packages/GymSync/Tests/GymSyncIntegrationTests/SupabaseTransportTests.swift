import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// `SupabaseTransport` against the local stack: the PostgREST/RPC behaviors the sync engine relies on.
@MainActor
@Suite(.enabled(if: supabaseConfigured, "Set SUPABASE_URL and SUPABASE_ANON_KEY to run against local Supabase"))
struct SupabaseTransportTests {
    private let t0 = SyncDate.parse("2026-09-27T08:00:00.123456Z")!

    /// Profile and week schedule upsert with `on_conflict` columns absent from the body (`user_id` comes from the
    /// column default `auth.uid()`), and a push older than the stored edit is skipped with no ack.
    @Test func profileAndWeekdayUpsertsUseTheCallerAsKeyAndSkipOlderEdits() async throws {
        let user = try await Account.signUp()
        let transport = user.transport
        var snapshot = ProfileSnapshot()
        snapshot.unit = .kg
        snapshot.heightCm = 180.3
        snapshot.platesKg = [20.411656, 0.1 + 0.2, 1.133981]
        let profile = ProfileDTO(SyncRow(value: snapshot, clientUpdatedAt: t0))

        let first = try #require(try await transport.push(profile: profile))
        #expect(first.id == SyncStore.profileSyncID)
        var newer = snapshot
        newer.restSec = 90
        #expect(try await transport.push(profile: ProfileDTO(SyncRow(value: newer, clientUpdatedAt: t0 + 60))) != nil)
        #expect(try await transport.push(profile: ProfileDTO(SyncRow(value: snapshot, clientUpdatedAt: t0 - 60))) == nil)

        let pulled = try #require(try await transport.pullProfile(since: nil).first)
        #expect(pulled.restSec == 90)
        #expect(pulled.platesKg == [20.411656, 0.1 + 0.2, 1.133981])  // numeric[] -> JSON numbers, exact
        #expect(pulled.heightCm == 180.3)
        #expect(pulled.clientUpdatedAt == t0 + 60)

        let days = [WeekdayDTO(SyncRow(value: WeekdayAssignment(weekday: 1, routineId: nil), clientUpdatedAt: t0)),
                    WeekdayDTO(SyncRow(value: WeekdayAssignment(weekday: 3, routineId: nil), clientUpdatedAt: t0))]
        #expect(Set(try await transport.push(weekdays: days).map(\.id)) == ["1", "3"])
        let mixed = [WeekdayDTO(SyncRow(value: WeekdayAssignment(weekday: 1, routineId: nil), clientUpdatedAt: t0 - 1)),
                     WeekdayDTO(SyncRow(value: WeekdayAssignment(weekday: 3, routineId: nil), clientUpdatedAt: t0 + 1))]
        #expect(try await transport.push(weekdays: mixed).map(\.id) == ["3"])  // only rows actually written
        #expect(try await transport.pullWeekdays(since: nil).map(\.weekday) == [1, 3])

        try await user.deleteAccount()
    }

    /// Weekly targets upsert on `(user_id, muscle)`, ack by muscle id, skip older edits and page by muscle.
    @Test func muscleTargetUpsertsAckByMuscleAndSkipOlderEdits() async throws {
        let user = try await Account.signUp()
        let transport = user.transport
        let row = { (group: MuscleGroup, min: Int, max: Int, at: Date) in
            MuscleTargetDTO(SyncRow(value: MuscleTargetValue(group: group, range: SetTargetRange(min: min, max: max)),
                                    clientUpdatedAt: at))
        }
        let acks = try await transport.push(muscleTargets: [row(.chest, 12, 18, t0), row(.upperBack, 8, 16, t0)])
        #expect(Set(acks.map(\.id)) == ["chest", "upper_back"])
        #expect(try await transport.push(muscleTargets: [row(.chest, 1, 2, t0 - 60)]).isEmpty)
        let pulled = try await transport.pullMuscleTargets(since: nil)
        #expect(pulled.map(\.muscle) == ["chest", "upper_back"])
        #expect(pulled.first?.minSets == 12)
        #expect(pulled.first?.updatedAt == acks.first { $0.id == "chest" }?.updatedAt)
        await #expect(throws: SyncRecordRejected.self) {
            _ = try await transport.push(muscleTargets: [row(.lats, 20, 10, t0)])
        }
        try await user.deleteAccount()
    }

    /// Upserts ack only the rows the LWW trigger let through; acked `updated_at` equals the pulled one exactly.
    @Test func batchUpsertAcksOnlyWrittenRowsAndTimestampsRoundTrip() async throws {
        let user = try await Account.signUp()
        let transport = user.transport
        let noisy = Date()  // sub-microsecond noise, as on device
        let kept = BodyweightEntry(date: noisy, weightKg: 81.3 * 1.000_000_1, bodyFatPct: 14.2, timeOfDay: "am")
        let other = BodyweightEntry(date: t0, weightKg: 82)
        let acks = try await transport.push(bodyweight: [
            BodyweightDTO(SyncRow(value: kept, clientUpdatedAt: t0)),
            BodyweightDTO(SyncRow(value: other, clientUpdatedAt: t0)),
        ])
        #expect(acks.count == 2)

        let staleEdit = BodyweightEntry(id: kept.id, date: noisy, weightKg: 99)
        let newerEdit = BodyweightEntry(id: other.id, date: t0, weightKg: 83)
        let second = try await transport.push(bodyweight: [
            BodyweightDTO(SyncRow(value: staleEdit, clientUpdatedAt: t0 - 0.000_001)),
            BodyweightDTO(SyncRow(value: newerEdit, clientUpdatedAt: t0 + 0.000_001)),
        ])
        #expect(second.map { $0.id.lowercased() } == [other.id.uuidString.lowercased()])

        let pulled = try await transport.pullBodyweight(since: nil)
        let keptRow = try #require(pulled.first { $0.id == kept.id })
        #expect(keptRow.wKg == 81.3 * 1.000_000_1)
        #expect(keptRow.measuredAt == SyncDate.truncatedToWire(noisy))
        #expect(keptRow.clientUpdatedAt == t0)
        #expect(keptRow.bfPct == 14.2)
        let otherRow = try #require(pulled.first { $0.id == other.id })
        #expect(otherRow.wKg == 83)
        #expect(otherRow.clientUpdatedAt == t0 + 0.000_001)
        #expect(otherRow.updatedAt == second.first?.updatedAt)
        #expect(pulled.map(\.id) == pulled.sorted { ($0.updatedAt!, $0.id.uuidString) < ($1.updatedAt!, $1.id.uuidString) }
            .map(\.id))

        let cursor = try #require(otherRow.updatedAt)
        #expect(try await transport.pullBodyweight(since: cursor).isEmpty)  // cursor doesn't re-match its own row

        try await user.deleteAccount()
    }

    /// `upsert_workout` stores the aggregate, answers `stale` for an older edit, and its `updated_at` matches the pull.
    @Test func workoutRPCStoresAggregateAndReportsStale() async throws {
        let user = try await Account.signUp()
        let transport = user.transport
        let workout = finishedWorkout(name: "Push", at: t0)
        let dto = WorkoutDTO(SyncRow(value: WorkoutSnapshot(workout: workout, records: benchRecords, volumeKg: 1_418.25),
                                     clientUpdatedAt: t0 + 3_000))

        guard case .ok(let stored) = try await transport.push(workout: dto) else {
            Issue.record("expected ok")
            return
        }
        let fetched = try #require(try await transport.fetchWorkout(id: workout.id))
        #expect(fetched.updatedAt == stored)
        #expect(fetched.toDomain().value == dto.toDomain().value)
        #expect(fetched.clientUpdatedAt == t0 + 3_000)
        #expect(try await transport.pullWorkouts(since: nil).map(\.id) == [workout.id])

        let older = WorkoutDTO(SyncRow(value: WorkoutSnapshot(workout: finishedWorkout(id: workout.id, name: "Old",
                                                                                        at: t0),
                                                              records: [], volumeKg: 0),
                                       clientUpdatedAt: t0 + 2_999))
        #expect(try await transport.push(workout: older) == .stale(updatedAt: stored))
        #expect(try await transport.fetchWorkout(id: workout.id)?.name == "Push")

        try await user.deleteAccount()
    }
}
