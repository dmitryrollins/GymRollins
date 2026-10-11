import Foundation
import GymData
import os

// Push and pull rounds.
extension SyncEngine {
    static let log = Logger(subsystem: "com.rollins.gymrollins", category: "sync")

    // MARK: Push

    /// Pushes every dirty row in dependency order; returns workout ids the server reported as stale.
    func pushAll() async throws -> Set<UUID> {
        try await pushProfile()
        try await pushBatch(.customExercises, rows: try store.dirtyCustomExercises(), key: { $0.value.id }, send: {
            try await self.transport.push(customExercises: $0.map(CustomExerciseDTO.init))
        })
        try await pushBatch(.exercisePreferences, rows: try store.dirtyExercisePreferences(),
                            key: { $0.value.exerciseId }, send: {
            try await self.transport.push(exercisePrefs: $0.map(ExercisePrefDTO.init))
        })
        try await pushBatch(.routines, rows: try store.dirtyRoutines(), key: { $0.value.routine.id.uuidString }, send: {
            try await self.transport.push(routines: $0.map(RoutineDTO.init))
        })
        try await pushBatch(.weekSchedule, rows: try store.dirtyWeekdays(), key: { String($0.value.weekday) }, send: {
            try await self.transport.push(weekdays: $0.map(WeekdayDTO.init))
        })
        try await pushBatch(.muscleTargets, rows: try store.dirtyMuscleTargets(), key: { $0.value.group.rawValue },
                            send: { try await self.transport.push(muscleTargets: $0.map(MuscleTargetDTO.init)) })
        try await pushProposals()
        try await pushBatch(.bodyweight, rows: try store.dirtyBodyweight(), key: { $0.value.id.uuidString }, send: {
            try await self.transport.push(bodyweight: $0.map(BodyweightDTO.init))
        })
        return try await pushWorkouts(only: nil, force: false)
    }

    private func pushProfile() async throws {
        let id = SyncStore.profileSyncID
        guard let row = try store.dirtyProfile(),
              !store.isSyncBlocked(.profile, id: id, clientUpdatedAt: row.clientUpdatedAt) else { return }
        do {
            let ack = try await transport.push(profile: ProfileDTO(row))
            try ensureLive()
            if let ack {
                try store.markSynced(.profile, id: id, clientUpdatedAt: row.clientUpdatedAt,
                                     serverUpdatedAt: ack.updatedAt)
            }
        } catch let rejected as SyncRecordRejected {
            try ensureLive()
            recordRejection(rejected, entity: .profile, id: id, clientUpdatedAt: row.clientUpdatedAt)
        }
    }

    /// Pushes dirty workouts (or just one), one RPC each, each on the server version it was edited from; returns the
    /// ids answered `stale` (changed elsewhere since). `force` (keep-local resolution only) overwrites the server.
    func pushWorkouts(only id: UUID?, force: Bool) async throws -> Set<UUID> {
        var stale = Set<UUID>()
        for row in try store.dirtyWorkouts() where id == nil || row.value.workout.id == id {
            let workoutId = row.value.workout.id
            guard !store.isSyncBlocked(.workouts, id: workoutId.uuidString, clientUpdatedAt: row.clientUpdatedAt)
            else { continue }
            let result: WorkoutPushResult
            do {
                result = try await transport.push(workout: WorkoutDTO(row, force: force))
                try ensureLive()
            } catch let rejected as SyncRecordRejected {
                try ensureLive()
                recordRejection(rejected, entity: .workouts, id: workoutId.uuidString,
                                clientUpdatedAt: row.clientUpdatedAt)
                continue
            }
            switch result {
            case .ok(let serverUpdatedAt):
                try store.markSynced(.workouts, id: workoutId.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                                     serverUpdatedAt: serverUpdatedAt)
            case .stale:
                stale.insert(workoutId)
            }
        }
        return stale
    }

    /// Upserts rows and marks the acknowledged ones synced. Rows without an ack were skipped by the server's
    /// last-write-wins guard; they stay dirty and the pull replaces them with the newer server edit. If the server
    /// refuses the batch because of one row's values, the rows are retried one by one and only the refused ones
    /// are recorded as failures.
    private func pushBatch<Value>(_ entity: SyncEntity, rows allRows: [SyncRow<Value>],
                                  key: (SyncRow<Value>) -> String,
                                  send: ([SyncRow<Value>]) async throws -> [RowAck]) async throws {
        let rows = allRows.filter { !store.isSyncBlocked(entity, id: key($0), clientUpdatedAt: $0.clientUpdatedAt) }
        guard !rows.isEmpty else { return }
        var acks: [RowAck] = []
        do {
            acks = try await send(rows)
            try ensureLive()
        } catch let rejected as SyncRecordRejected {
            try ensureLive()
            if rows.count == 1, let row = rows.first {
                recordRejection(rejected, entity: entity, id: key(row), clientUpdatedAt: row.clientUpdatedAt)
            } else {
                for row in rows {
                    do {
                        acks += try await send([row])
                        try ensureLive()
                    } catch let single as SyncRecordRejected {
                        try ensureLive()
                        recordRejection(single, entity: entity, id: key(row), clientUpdatedAt: row.clientUpdatedAt)
                    }
                }
            }
        }
        let byId = Dictionary(acks.map { ($0.id.lowercased(), $0.updatedAt) }, uniquingKeysWith: { _, last in last })
        for row in rows {
            let id = key(row)
            guard let serverUpdatedAt = byId[id.lowercased()] else { continue }
            try store.markSynced(entity, id: id, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: serverUpdatedAt)
        }
    }

    /// Sends each local proposal resolution (after routines/weekdays, so the plan it changed is already there).
    /// A refused update is recorded as a sync failure and not re-sent until the resolution changes (same policy as
    /// every other entity).
    private func pushProposals() async throws {
        for row in try store.dirtyProposals()
        where !store.isSyncBlocked(.proposals, id: row.id.uuidString, clientUpdatedAt: row.updatedAt) {
            do {
                try await transport.resolveProposal(id: row.id, status: row.status.rawValue,
                                                    appliedChangeIds: row.appliedChangeIds, at: row.resolvedAt)
                try ensureLive()
            } catch let rejected as SyncRecordRejected {
                try ensureLive()
                recordRejection(rejected, entity: .proposals, id: row.id.uuidString, clientUpdatedAt: row.updatedAt)
                continue
            }
            try store.markProposalSynced(row.id, clientUpdatedAt: row.updatedAt)
        }
    }

    private func recordRejection(_ rejected: SyncRecordRejected, entity: SyncEntity, id: String,
                                 clientUpdatedAt: Date) {
        store.recordSyncFailure(SyncFailure(entity: entity, id: id, clientUpdatedAt: clientUpdatedAt,
                                            message: rejected.message))
    }

    // MARK: Pull

    /// Pulls every entity since its cursor; returns conflicting workout ids.
    func pullAll() async throws -> Set<UUID> {
        try await pull(.profile, fetch: { try await self.transport.pullProfile(since: $0) }, apply: { dtos in
            try dtos.forEach { try self.store.applyRemote(profile: $0.toDomain()) }
        })
        try await pull(.customExercises, fetch: { try await self.transport.pullCustomExercises(since: $0) }, apply: {
            try self.store.applyRemote(customExercises: $0.map { $0.toDomain() })
        })
        try await pull(.exercisePreferences, fetch: { try await self.transport.pullExercisePrefs(since: $0) }, apply: {
            try self.store.applyRemote(exercisePreferences: $0.map { $0.toDomain() })
        })
        try await pull(.routines, fetch: { try await self.transport.pullRoutines(since: $0) }, apply: {
            try self.store.applyRemote(routines: $0.map { $0.toDomain() })
        })
        try await pull(.weekSchedule, fetch: { try await self.transport.pullWeekdays(since: $0) }, apply: {
            try self.store.applyRemote(weekdays: $0.map { $0.toDomain() })
        })
        try await pull(.muscleTargets, fetch: { try await self.transport.pullMuscleTargets(since: $0) }, apply: {
            try self.store.applyRemote(muscleTargets: $0.compactMap { $0.toDomain() })
        })
        try await pull(.bodyweight, fetch: { try await self.transport.pullBodyweight(since: $0) }, apply: {
            try self.store.applyRemote(bodyweight: $0.map { $0.toDomain() })
        })
        var conflicts = Set<UUID>()
        try await pull(.workouts, fetch: { try await self.transport.pullWorkouts(since: $0) }, apply: {
            conflicts = Set(try self.store.applyRemote(workouts: $0.map { $0.toDomain() }))
        })
        try await pullProposals()
        return conflicts
    }

    /// The server's full pending list (small; no cursor): new proposals are stored, ones resolved elsewhere dropped.
    /// A row the app can't read is skipped, logged and recorded as a sync failure; the others still sync.
    private func pullProposals() async throws {
        let before = try store.pendingProposalIds()
        let pulled = try await transport.pendingProposals()
        try ensureLive()
        var valid: [ProposalDTO] = []
        for row in pulled {
            switch row {
            case .valid(let dto): valid.append(dto)
            case .malformed(let bad):
                Self.log.error("Skipped proposal \(bad.id, privacy: .public): \(bad.message, privacy: .public)")
                store.recordSyncFailure(SyncFailure(entity: .proposals, id: bad.id,
                                                    clientUpdatedAt: bad.createdAt ?? .distantPast,
                                                    message: bad.message))
            }
        }
        try store.applyRemote(proposals: valid.map { $0.toDomain() })
        try store.pruneProposalFailures(malformedIds: Set(pulled.compactMap {
            if case .malformed(let bad) = $0 { bad.id } else { nil }
        }))
        if try store.pendingProposalIds() != before { noteRemoteChanges() }
    }

    /// Fetches rows newer than the entity's cursor, applies them, then advances the cursor to the newest
    /// `updated_at` seen (only after a successful apply, so a failure re-pulls the same rows next time).
    private func pull<DTO: ServerStamped>(_ entity: SyncEntity, fetch: (Date?) async throws -> [DTO],
                                          apply: ([DTO]) throws -> Void) async throws {
        let since = store.cursor(for: entity)
        let dtos = try await fetch(since)
        try ensureLive()
        guard !dtos.isEmpty else { return }
        try apply(dtos)
        noteRemoteChanges()
        if let newest = dtos.compactMap(\.updatedAt).max(), newest > (since ?? .distantPast) {
            store.setCursor(newest, for: entity)
        }
    }
}
