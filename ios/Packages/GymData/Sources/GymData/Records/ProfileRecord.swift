import Foundation
import GymCore
import SwiftData

@Model
public final class ProfileRecord {
    @Attribute(.unique) public var id: UUID
    public var unitRaw: String
    public var restSec: Int
    public var warmupRestSec: Int
    public var heightCm: Double?
    public var goalWeightKg: Double?
    public var goalDate: Date?
    public var trainingDays: Int
    public var experience: String
    public var limits: String
    public var deloadPct: Double
    public var barKg: Double
    /// Available plate sizes per side, in kg (unlimited count of each) — like `barKg`, always kg
    /// regardless of display unit, so switching `unitRaw` never reinterprets the raw numbers.
    public var platesKg: [Double]
    public var dumbbellStepKg: Double
    public var mcpReadWorkouts: Bool
    public var mcpReadBody: Bool
    public var mcpReadPlan: Bool = true
    public var mcpPropose: Bool
    public var mcpAutoApply: Bool
    /// `ProfileSex` raw value; nil until the owner sets it (strength levels only).
    public var sexRaw: String?
    public var birthYear: Int?
    // sync
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool

    public init(id: UUID = ProfileRecord.singletonID, now: Date = .now) {
        self.id = id
        self.unitRaw = "lb"
        self.restSec = 120
        self.warmupRestSec = 60
        self.trainingDays = 4
        self.experience = "intermediate"
        self.limits = ""
        self.deloadPct = 0.05
        self.barKg = 20.411656
        self.platesKg = [45, 35, 25, 10, 5, 2.5].map { UnitConverter.toKg($0, from: .lb) }
        self.dumbbellStepKg = 1.133981
        self.mcpReadWorkouts = true
        self.mcpReadBody = true
        self.mcpPropose = true
        self.mcpAutoApply = false
        self.updatedAt = now
        self.dirty = true
    }

    public static let singletonID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!
}
