import Foundation
import GymCore

public struct Profile: Codable, Sendable, Equatable {
    public let unit: WeightUnit
    public let restSec: Int
    public let warmupRestSec: Int
    public let heightCm: Double?
    public let goalWeightKg: Double?
    public let goalDate: Date?
    public let trainingDays: Int
    public let experience: String
    public let limits: String
    public let deloadPct: Double
    public let barKg: Double
    public let plateInventory: PlateInventory
    public let dumbbellStepKg: Double
    public let mcpReadWorkouts: Bool
    public let mcpReadBody: Bool
    /// Claude may read the plan (routines, schedule, custom exercises) and this profile.
    public let mcpReadPlan: Bool
    public let mcpPropose: Bool
    public let mcpAutoApply: Bool
    /// Optional; only picks the strength-level comparison table. `ProfileRepository.save` never writes it (see
    /// `setStrengthProfile`), so screens that rebuild a profile can't clear it.
    public let sex: ProfileSex?
    /// Optional (`DomainLimits.birthYear`); like `sex`, only for strength levels.
    public let birthYear: Int?

    public init(unit: WeightUnit = .lb, restSec: Int = 120, warmupRestSec: Int = 60, heightCm: Double? = nil,
                goalWeightKg: Double? = nil, goalDate: Date? = nil, trainingDays: Int = 4,
                experience: String = "intermediate", limits: String = "", deloadPct: Double = 0.05,
                barKg: Double = 20.411656, plateInventory: PlateInventory = .standardLb,
                dumbbellStepKg: Double = 1.133981, mcpReadWorkouts: Bool = true, mcpReadBody: Bool = true,
                mcpReadPlan: Bool = true, mcpPropose: Bool = true, mcpAutoApply: Bool = false,
                sex: ProfileSex? = nil, birthYear: Int? = nil) {
        self.unit = unit
        self.restSec = restSec
        self.warmupRestSec = warmupRestSec
        self.heightCm = heightCm
        self.goalWeightKg = goalWeightKg
        self.goalDate = goalDate
        self.trainingDays = trainingDays
        self.experience = experience
        self.limits = limits
        self.deloadPct = deloadPct
        self.barKg = barKg
        self.plateInventory = plateInventory
        self.dumbbellStepKg = dumbbellStepKg
        self.mcpReadWorkouts = mcpReadWorkouts
        self.mcpReadBody = mcpReadBody
        self.mcpReadPlan = mcpReadPlan
        self.mcpPropose = mcpPropose
        self.mcpAutoApply = mcpAutoApply
        self.sex = sex
        self.birthYear = birthYear
    }

    /// Rounder for barbell-style loads in the user's unit: totals loadable from the bar and the enabled plates
    /// (`LoadRounder.barbell(inventory:)`); the unit's standard rounder when the inventory is in another unit.
    public var barbellRounder: LoadRounder {
        guard plateInventory.unit == unit else { return unit == .lb ? .barbellLb : .barbellKg }
        return .barbell(inventory: plateInventory)
    }
    /// Rounder for dumbbells/machines in the user's unit.
    public var dumbbellRounder: LoadRounder {
        LoadRounder(unit: unit, step: UnitConverter.fromKg(dumbbellStepKg, to: unit).rounded(toPlaces: 2))
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
