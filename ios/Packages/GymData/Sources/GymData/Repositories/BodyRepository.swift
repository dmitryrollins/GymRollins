import Foundation
import GymCore
import SwiftData

@MainActor
public final class BodyRepository {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    public func entries(since: Date?) throws -> [BodyweightEntry] {
        let start = since ?? .distantPast
        let d = FetchDescriptor<BodyweightRecord>(predicate: #Predicate { $0.deletedAt == nil && $0.date >= start },
                                                  sortBy: [SortDescriptor(\.date)])
        return try context.fetch(d).map(\.entry)
    }

    public func latest() throws -> BodyweightEntry? { try entries(since: nil).last }

    /// `editedAt` (default: now) is the edit time sync compares: an Apple Health import passes the sample's own date,
    /// so a newer cloud deletion of the same weigh-in still wins.
    public func add(_ e: BodyweightEntry, editedAt: Date? = nil) throws {
        if let violation = DomainLimits.bodyweightViolation(weightKg: e.weightKg, bodyFatPct: e.bodyFatPct) {
            throw GymDataError.invalidInput(violation)
        }
        let record = BodyweightRecord(id: e.id, date: e.date, weightKg: e.weightKg, bodyFatPct: e.bodyFatPct,
                                      timeOfDay: e.timeOfDay, now: editedAt ?? now(), source: e.source)
        record.healthSampleId = e.healthSampleId
        record.healthFatSampleId = e.healthFatSampleId
        context.insert(record)
        try context.save()
    }

    /// Inserts the weigh-in, or updates the live one with the same id in place (date, weight, body fat, time of day).
    public func upsert(_ e: BodyweightEntry, editedAt: Date? = nil) throws {
        let id = e.id
        guard let r = try context.fetch(FetchDescriptor<BodyweightRecord>(
            predicate: #Predicate { $0.id == id && $0.deletedAt == nil })).first else {
            try add(e, editedAt: editedAt)
            return
        }
        if let violation = DomainLimits.bodyweightViolation(weightKg: e.weightKg, bodyFatPct: e.bodyFatPct) {
            throw GymDataError.invalidInput(violation)
        }
        r.date = e.date
        r.weightKg = e.weightKg
        r.bodyFatPct = e.bodyFatPct
        r.timeOfDay = e.timeOfDay
        r.source = e.source
        r.healthSampleId = e.healthSampleId
        r.healthFatSampleId = e.healthFatSampleId
        // Never backwards: sync's last-write-wins (and the server's guard) compare edit times.
        r.updatedAt = max(editedAt ?? now(), r.updatedAt.addingTimeInterval(0.001))
        r.dirty = true
        try context.save()
    }

    /// True when a row with this id exists, including a deleted one (a tombstone).
    public func hasRecord(id: UUID) throws -> Bool {
        try context.fetchCount(FetchDescriptor<BodyweightRecord>(predicate: #Predicate { $0.id == id })) > 0
    }

    /// True when a row (live or deleted) came from this Health body mass sample.
    public func hasRecord(healthSampleId id: UUID) throws -> Bool {
        try context.fetchCount(FetchDescriptor<BodyweightRecord>(predicate: #Predicate { $0.healthSampleId == id })) > 0
    }

    /// The live weigh-in read from this Health body mass sample.
    public func entry(healthSampleId id: UUID) throws -> BodyweightEntry? {
        try context.fetch(FetchDescriptor<BodyweightRecord>(
            predicate: #Predicate { $0.healthSampleId == id && $0.deletedAt == nil })).first?.entry
    }

    /// The live weigh-in whose body fat came from this Health sample.
    public func entry(healthFatSampleId id: UUID) throws -> BodyweightEntry? {
        try context.fetch(FetchDescriptor<BodyweightRecord>(
            predicate: #Predicate { $0.healthFatSampleId == id && $0.deletedAt == nil })).first?.entry
    }

    public func delete(_ id: UUID) throws {
        guard let r = try context.fetch(FetchDescriptor<BodyweightRecord>(predicate: #Predicate { $0.id == id })).first
        else { return }
        r.deletedAt = now()
        r.updatedAt = now()
        r.dirty = true
        try context.save()
    }
}
