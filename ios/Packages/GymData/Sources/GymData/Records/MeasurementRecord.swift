import Foundation
import GymCore
import SwiftData

/// What Apple Health measured during one GymRollins workout (plan 40): the numbers that sync, one row per workout id.
/// Heart-rate readings stay in Health. No tombstone: the row goes when its workout is deleted, here or on another
/// device (`remove(for:in:)`). The server's copy is then never read, and its foreign key drops it with the workout's
/// row.
@Model
public final class MeasurementRecord {
    @Attribute(.unique) public var workoutId: UUID
    /// `MeasurementSnapshot.RecordedBy`'s raw value: "watch" or "apple_workout".
    public var recordedByRaw: String?
    public var durationS: Double?
    public var activeKcal: Double?
    public var totalKcal: Double?
    public var avgHr: Int?
    public var maxHr: Int?
    public var postHr: Int?
    public var effort: Int?
    public var effortEstimated: Bool
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool

    /// A new row holding `snapshot`, edited at its `clientUpdatedAt`, waiting to sync.
    public init(_ snapshot: MeasurementSnapshot) {
        self.workoutId = snapshot.workoutId
        self.recordedByRaw = snapshot.recordedBy?.rawValue
        self.durationS = snapshot.durationS
        self.activeKcal = snapshot.activeKcal
        self.totalKcal = snapshot.totalKcal
        self.avgHr = snapshot.avgHr
        self.maxHr = snapshot.maxHr
        self.postHr = snapshot.postHr
        self.effort = snapshot.effort
        self.effortEstimated = snapshot.effortEstimated
        self.updatedAt = snapshot.clientUpdatedAt
        self.dirty = true
    }

    /// The stored numbers, with the row's edit time as their `clientUpdatedAt`.
    public var value: MeasurementSnapshot {
        MeasurementSnapshot(workoutId: workoutId,
                            recordedBy: recordedByRaw.flatMap(MeasurementSnapshot.RecordedBy.init(rawValue:)),
                            durationS: durationS, activeKcal: activeKcal, totalKcal: totalKcal, avgHr: avgHr,
                            maxHr: maxHr, postHr: postHr, effort: effort, effortEstimated: effortEstimated,
                            clientUpdatedAt: updatedAt)
    }

    /// Takes every number of `snapshot` (the workout id and the edit time stay).
    func apply(_ snapshot: MeasurementSnapshot) {
        recordedByRaw = snapshot.recordedBy?.rawValue
        durationS = snapshot.durationS
        activeKcal = snapshot.activeKcal
        totalKcal = snapshot.totalKcal
        avgHr = snapshot.avgHr
        maxHr = snapshot.maxHr
        postHr = snapshot.postHr
        effort = snapshot.effort
        effortEstimated = snapshot.effortEstimated
    }

    /// This workout's row, if there is one.
    static func of(_ workoutId: UUID, in context: ModelContext) throws -> MeasurementRecord? {
        try context.fetch(FetchDescriptor<MeasurementRecord>(predicate: #Predicate { $0.workoutId == workoutId }))
            .first
    }

    /// The workout was deleted: its row goes too. The caller saves the context.
    static func remove(for workoutId: UUID, in context: ModelContext) throws {
        if let record = try of(workoutId, in: context) { context.delete(record) }
    }
}
