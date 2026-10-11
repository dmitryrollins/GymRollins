import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymSync

/// Keyset-paged pulls and row rejections against the local stack.
@MainActor
@Suite(.enabled(if: supabaseConfigured, "Set SUPABASE_URL and SUPABASE_ANON_KEY to run against local Supabase"))
struct PagingAndRejectionTests {
    private let t0 = SyncDate.parse("2026-09-27T08:00:00.123456Z")!

    /// 7 weigh-ins written by ONE upsert share `updated_at`; with page size 3 every row arrives exactly once,
    /// and the cursor semantics (`updated_at > since`) still hold.
    @Test func pullPagesByUpdatedAtAndIdAcrossSharedTimestamps() async throws {
        let user = try await Account.signUp()
        let small = SupabaseTransport(client: user.auth.client, pageSize: 3)
        let entries = (0..<7).map { BodyweightEntry(date: t0 + Double($0) * 86_400, weightKg: 80 + Double($0) / 10) }
        _ = try await small.push(bodyweight: entries.map { BodyweightDTO(SyncRow(value: $0, clientUpdatedAt: t0)) })
        let later = BodyweightEntry(date: t0 + 30 * 86_400, weightKg: 85)
        _ = try await small.push(bodyweight: [BodyweightDTO(SyncRow(value: later, clientUpdatedAt: t0))])

        let all = try await small.pullBodyweight(since: nil)
        #expect(all.count == 8)
        #expect(Set(all.map(\.id)) == Set((entries + [later]).map(\.id)))
        let sharedStamp = try #require(all.first?.updatedAt)
        #expect(all.prefix(7).allSatisfy { $0.updatedAt == sharedStamp })

        let sinceShared = try await small.pullBodyweight(since: sharedStamp)
        #expect(sinceShared.map(\.id) == [later.id])

        // Workouts (nested select, rpc-written) page the same way.
        for i in 0..<4 {
            let w = finishedWorkout(name: "W\(i)", at: t0 + Double(i) * 3_600)
            let row = SyncRow(value: WorkoutSnapshot(workout: w, records: [], volumeKg: 1_000), clientUpdatedAt: t0)
            _ = try await small.push(workout: WorkoutDTO(row))
        }
        let workouts = try await small.pullWorkouts(since: nil)
        #expect(workouts.count == 4)
        #expect(workouts.allSatisfy { $0.entries.first?.sets.count == 3 })

        try await user.deleteAccount()
    }

    /// A CHECK violation comes back as `SyncRecordRejected` (not a generic error that would abort the round).
    @Test func checkViolationIsARowRejection() async throws {
        let user = try await Account.signUp()
        let transport = user.transport
        let tooLong = Routine(name: String(repeating: "x", count: 41), exercises: [])
        let dto = RoutineDTO(SyncRow(value: RoutineSnapshot(routine: tooLong, position: 0), clientUpdatedAt: t0))
        await #expect(throws: SyncRecordRejected.self) { try await transport.push(routines: [dto]) }

        let bad = BodyweightEntry(date: t0, weightKg: 500)
        do {
            _ = try await transport.push(bodyweight: [BodyweightDTO(SyncRow(value: bad, clientUpdatedAt: t0))])
            Issue.record("Expected a rejection")
        } catch let rejected as SyncRecordRejected {
            #expect(rejected.code == "23514")
            #expect(rejected.message.contains("check constraint"))
        }
        try await user.deleteAccount()
    }

    /// End to end: one refused routine is recorded and everything else still syncs.
    @Test func engineSkipsTheRefusedRowAndSyncsTheRest() async throws {
        let user = try await Account.signUp()
        let clock = DeviceClock("2026-09-27T09:00:00Z")
        let device = try Device(user, clock: clock)
        defer { device.tearDown() }
        try device.routines.upsert(Routine(name: "Push", exercises: []))
        try device.body.add(BodyweightEntry(date: clock.now, weightKg: 81))
        // Simulate an out-of-range record that predates local validation: write it past the repository.
        let rogue = Routine(name: String(repeating: "y", count: 41), exercises: [])
        try device.store.applyRemote(routines: [SyncRow(value: RoutineSnapshot(routine: rogue, position: 1),
                                                        clientUpdatedAt: clock.now)])
        let rogueId = rogue.id
        let record = try #require(try device.container.mainContext.fetch(
            FetchDescriptor<RoutineRecord>(predicate: #Predicate { $0.id == rogueId })).first)
        record.dirty = true
        try device.container.mainContext.save()

        await device.engine.sync()

        #expect(device.engine.status == .idle)
        #expect(device.store.syncFailures().map(\.entity) == [.routines])
        let server = try await user.transport.pullRoutines(since: nil)
        #expect(server.map(\.name) == ["Push"])
        #expect(try await user.transport.pullBodyweight(since: nil).count == 1)
        try await user.deleteAccount()
    }
}
