import Foundation
import GymCore
import SwiftData

// Profile, custom exercises and bodyweight.
extension SyncStore {
    // MARK: Profile

    public func dirtyProfile() throws -> SyncRow<ProfileSnapshot>? {
        guard let r = try profileRecord(), r.dirty else { return nil }
        return SyncRow(value: r.snapshot, clientUpdatedAt: r.updatedAt, serverUpdatedAt: r.serverUpdatedAt)
    }

    public func applyRemote(profile row: SyncRow<ProfileSnapshot>) throws {
        let existing = try profileRecord()
        if let existing, !remoteWins(over: existing, remoteEdit: row.clientUpdatedAt) { return }
        let r = existing ?? {
            let new = ProfileRecord(now: row.clientUpdatedAt)
            context.insert(new)
            return new
        }()
        r.apply(row.value)
        markClean(r, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: row.serverUpdatedAt)
        try context.save()
    }

    // MARK: Custom exercises

    public func dirtyCustomExercises() throws -> [SyncRow<Exercise>] {
        try context.fetch(FetchDescriptor<CustomExerciseRecord>(predicate: #Predicate { $0.dirty }))
            .map { SyncRow(value: $0.exercise, clientUpdatedAt: $0.updatedAt, deletedAt: $0.deletedAt,
                           serverUpdatedAt: $0.serverUpdatedAt) }
    }

    public func applyRemote(customExercises rows: [SyncRow<Exercise>]) throws {
        for row in rows {
            let ex = row.value
            let existing = try customExerciseRecord(ex.id)
            if let existing, !remoteWins(over: existing, remoteEdit: row.clientUpdatedAt) { continue }
            if existing == nil && row.deletedAt != nil { continue }
            let r = existing ?? {
                let new = CustomExerciseRecord(id: ex.id, name: ex.name, bodyPart: ex.bodyPart, equipment: ex.equipment,
                                               target: ex.target, modeRaw: ex.mode.rawValue, bilateral: ex.bilateral,
                                               now: row.clientUpdatedAt)
                context.insert(new)
                return new
            }()
            r.name = ex.name
            r.bodyPart = ex.bodyPart
            r.equipment = ex.equipment
            r.target = ex.target
            r.modeRaw = ex.mode.rawValue
            r.bilateral = ex.bilateral
            r.deletedAt = row.deletedAt
            markClean(r, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: row.serverUpdatedAt)
        }
        try context.save()
    }

    // MARK: Bodyweight

    public func dirtyBodyweight() throws -> [SyncRow<BodyweightEntry>] {
        try context.fetch(FetchDescriptor<BodyweightRecord>(predicate: #Predicate { $0.dirty }))
            .map { SyncRow(value: $0.entry, clientUpdatedAt: $0.updatedAt, deletedAt: $0.deletedAt,
                           serverUpdatedAt: $0.serverUpdatedAt) }
    }

    public func applyRemote(bodyweight rows: [SyncRow<BodyweightEntry>]) throws {
        for row in rows {
            let e = row.value
            let existing = try bodyweightRecord(e.id)
            // Deleting a measurement read from Health beats newer automatic edits (merges, cleanups) of that row.
            let healthDeletion = row.deletedAt != nil && e.healthSampleId != nil && existing?.source == .appleHealth
            // ...and a deletion made here isn't undone by a live copy of the same row (the server accepts ours).
            if let existing, existing.deletedAt != nil, existing.healthSampleId != nil, row.deletedAt == nil { continue }
            if let existing, !healthDeletion, !remoteWins(over: existing, remoteEdit: row.clientUpdatedAt) { continue }
            // A remote tombstone with no local row is skipped, except for Apple Health weigh-ins: kept, it tells the
            // Health import that this sample was deleted (else the import would re-create it and sync resurrect it).
            if existing == nil && row.deletedAt != nil && e.source != .appleHealth { continue }
            if row.deletedAt != nil, let sample = e.healthSampleId { try deleteHealthTwins(sample, except: e.id) }
            var keptFat: (pct: Double?, sample: UUID?)?
            var deleteRemote: Bool? // clear the sample ids too?
            if row.deletedAt == nil {
                switch try reconcileHealthDuplicate(e, remoteEdit: row.clientUpdatedAt) {
                case .deleteRemote(let clearSample): deleteRemote = clearSample
                case .apply(let fat): keptFat = fat
                }
            }
            let r = existing ?? {
                let new = BodyweightRecord(id: e.id, date: e.date, weightKg: e.weightKg, bodyFatPct: e.bodyFatPct,
                                           timeOfDay: e.timeOfDay, now: row.clientUpdatedAt, source: e.source)
                context.insert(new)
                return new
            }()
            r.date = e.date
            r.weightKg = e.weightKg
            r.bodyFatPct = e.bodyFatPct
            r.timeOfDay = e.timeOfDay
            r.source = e.source
            r.healthSampleId = e.healthSampleId
            r.healthFatSampleId = e.healthFatSampleId
            r.deletedAt = row.deletedAt
            markClean(r, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: row.serverUpdatedAt)
            if let keptFat, r.bodyFatPct != keptFat.pct || r.healthFatSampleId != keptFat.sample { // the discarded copy was edited later: its body fat wins
                r.bodyFatPct = keptFat.pct
                r.healthFatSampleId = keptFat.sample
                touch(r)
            }
            if let clearSample = deleteRemote { // a duplicate (or a deleted measurement's twin): delete it everywhere
                r.deletedAt = now()
                if clearSample {
                    r.healthSampleId = nil
                    r.healthFatSampleId = nil
                    bumpMinimally(r)
                } else {
                    touch(r)
                }
            }
        }
        try context.save()
    }
}

extension ProfileRecord {
    var snapshot: ProfileSnapshot {
        var s = ProfileSnapshot()
        s.unit = WeightUnit(rawValue: unitRaw) ?? .lb
        s.restSec = restSec
        s.warmupRestSec = warmupRestSec
        s.heightCm = heightCm
        s.goalWeightKg = goalWeightKg
        s.goalDate = goalDate
        s.trainingDays = trainingDays
        s.experience = experience
        s.limits = limits
        s.deloadPct = deloadPct
        s.barKg = barKg
        s.platesKg = platesKg
        s.dumbbellStepKg = dumbbellStepKg
        s.mcpReadWorkouts = mcpReadWorkouts
        s.mcpReadBody = mcpReadBody
        s.mcpReadPlan = mcpReadPlan
        s.mcpPropose = mcpPropose
        s.mcpAutoApply = mcpAutoApply
        s.sex = sexRaw.flatMap(ProfileSex.init(rawValue:))
        s.birthYear = birthYear
        return s
    }

    func apply(_ s: ProfileSnapshot) {
        unitRaw = s.unit.rawValue
        restSec = s.restSec
        warmupRestSec = s.warmupRestSec
        heightCm = s.heightCm
        goalWeightKg = s.goalWeightKg
        goalDate = s.goalDate
        trainingDays = s.trainingDays
        experience = s.experience
        limits = s.limits
        deloadPct = s.deloadPct
        barKg = s.barKg
        platesKg = s.platesKg
        dumbbellStepKg = s.dumbbellStepKg
        mcpReadWorkouts = s.mcpReadWorkouts
        mcpReadBody = s.mcpReadBody
        mcpReadPlan = s.mcpReadPlan
        mcpPropose = s.mcpPropose
        mcpAutoApply = s.mcpAutoApply
        sexRaw = s.sex?.rawValue
        birthYear = s.birthYear
    }
}

extension CustomExerciseRecord {
    var exercise: Exercise {
        Exercise(id: id, name: name, bodyPart: bodyPart, equipment: equipment, target: target, isCustom: true,
                 mode: ExerciseMode(rawValue: modeRaw), bilateral: bilateral)
    }
}

extension SyncStore {
    enum HealthDuplicate {
        /// Store the remote row as deleted (and push that): a local copy with a smaller id wins (`clearSample`, a
        /// duplicate discard), or this sample was deleted here under another row id.
        case deleteRemote(clearSample: Bool)
        /// Apply it; `fat` overrides its body fat when a discarded local copy was edited later (nil value: none).
        case apply(fat: (pct: Double?, sample: UUID?)?)
    }

    /// Two devices can import the same Apple Health sample under different row ids before either sees the other's.
    /// Both converge on the smaller id: a remote copy with a larger id is ignored (its device deletes it), a local
    /// copy with a larger id is deleted. Body fat only one copy has moves to the kept row. The discard tombstone
    /// drops its sample id, so it never reads as the user deleting that measurement (`deleteHealthTwins`).
    func reconcileHealthDuplicate(_ remote: BodyweightEntry, remoteEdit: Date) throws -> HealthDuplicate {
        guard let sample = remote.healthSampleId else { return .apply(fat: nil) }
        let remoteId = remote.id
        let deletedHere = try context.fetchCount(FetchDescriptor<BodyweightRecord>(predicate: #Predicate {
            $0.healthSampleId == sample && $0.deletedAt != nil && $0.id != remoteId
        })) > 0
        if deletedHere { return .deleteRemote(clearSample: false) }
        let twins = try context.fetch(FetchDescriptor<BodyweightRecord>(predicate: #Predicate {
            $0.healthSampleId == sample && $0.deletedAt == nil && $0.id != remoteId
        }))
        guard !twins.isEmpty else { return .apply(fat: nil) }
        if let keeper = twins.first(where: { $0.id.uuidString < remoteId.uuidString }) {
            // The most recently edited copy's body fat wins, including none (it may have been deleted there).
            if remoteEdit > keeper.updatedAt,
               keeper.bodyFatPct != remote.bodyFatPct || keeper.healthFatSampleId != remote.healthFatSampleId {
                keeper.bodyFatPct = remote.bodyFatPct
                keeper.healthFatSampleId = remote.healthFatSampleId
                touch(keeper)
            }
            return .deleteRemote(clearSample: true)
        }
        let fat = twins.filter { $0.updatedAt > remoteEdit }.max { $0.updatedAt < $1.updatedAt }
            .map { (pct: $0.bodyFatPct, sample: $0.healthFatSampleId) }
        for twin in twins {
            twin.deletedAt = now()
            twin.healthSampleId = nil
            twin.healthFatSampleId = nil
            bumpMinimally(twin)
        }
        return .apply(fat: fat)
    }

    /// A weigh-in read from Health was deleted (on some device): its copies under other row ids go too.
    func deleteHealthTwins(_ sample: UUID, except id: UUID) throws {
        let twins = try context.fetch(FetchDescriptor<BodyweightRecord>(predicate: #Predicate {
            $0.healthSampleId == sample && $0.deletedAt == nil && $0.id != id
        }))
        for twin in twins {
            twin.deletedAt = now()
            touch(twin)
        }
    }

    /// Duplicate cleanup: only just newer than the row's last edit, so a real deletion or edit elsewhere still wins.
    private func bumpMinimally(_ r: BodyweightRecord) {
        r.updatedAt = r.updatedAt.addingTimeInterval(0.001)
        r.dirty = true
    }

    func touch(_ r: BodyweightRecord) {
        r.updatedAt = max(now(), r.updatedAt.addingTimeInterval(0.001))
        r.dirty = true
    }
}

extension BodyweightRecord {
    var entry: BodyweightEntry {
        BodyweightEntry(id: id, date: date, weightKg: weightKg, bodyFatPct: bodyFatPct, timeOfDay: timeOfDay,
                        source: source, healthSampleId: healthSampleId, healthFatSampleId: healthFatSampleId)
    }
}
