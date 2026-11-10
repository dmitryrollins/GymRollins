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
    /// The day the injury note is meant to end, a calendar day like `goalDate`; nil for none. Only counts with a note.
    public let limitsUntil: Date?
    public let deloadPct: Double
    public let barKg: Double
    public let plateInventory: PlateInventory
    public let dumbbellStepKg: Double
    public let mcpReadWorkouts: Bool
    public let mcpReadBody: Bool
    /// Claude may read the plan (routines, schedule, custom exercises) and this profile.
    public let mcpReadPlan: Bool
    /// Claude may read the gyms that are synced or shared (never the "This phone only" ones).
    public let mcpReadGyms: Bool
    public let mcpPropose: Bool
    public let mcpAutoApply: Bool
    /// Agents may add past workouts to the history (`log_workout`, plan 32); off by default.
    public let mcpLogWorkouts: Bool
    /// Optional; only picks the strength-level comparison table. `ProfileRepository.save` never writes it (see
    /// `setStrengthProfile`), so screens that rebuild a profile can't clear it.
    public let sex: ProfileSex?
    /// Optional (`DomainLimits.birthYear`); like `sex`, only for strength levels.
    public let birthYear: Int?

    public init(unit: WeightUnit = .lb, restSec: Int = 120, warmupRestSec: Int = 60, heightCm: Double? = nil,
                goalWeightKg: Double? = nil, goalDate: Date? = nil, trainingDays: Int = 4,
                experience: String = "intermediate", limits: String = "", limitsUntil: Date? = nil, deloadPct: Double = 0.05,
                barKg: Double = 20.411656, plateInventory: PlateInventory = .standardLb,
                dumbbellStepKg: Double = 1.133981, mcpReadWorkouts: Bool = true, mcpReadBody: Bool = true,
                mcpReadPlan: Bool = true, mcpReadGyms: Bool = true, mcpPropose: Bool = true,
                mcpAutoApply: Bool = false, mcpLogWorkouts: Bool = false, sex: ProfileSex? = nil,
                birthYear: Int? = nil) {
        self.unit = unit
        self.restSec = restSec
        self.warmupRestSec = warmupRestSec
        self.heightCm = heightCm
        self.goalWeightKg = goalWeightKg
        self.goalDate = goalDate
        self.trainingDays = trainingDays
        self.experience = experience
        self.limits = limits
        self.limitsUntil = limitsUntil
        self.deloadPct = deloadPct
        self.barKg = barKg
        self.plateInventory = plateInventory
        self.dumbbellStepKg = dumbbellStepKg
        self.mcpReadWorkouts = mcpReadWorkouts
        self.mcpReadBody = mcpReadBody
        self.mcpReadPlan = mcpReadPlan
        self.mcpReadGyms = mcpReadGyms
        self.mcpPropose = mcpPropose
        self.mcpAutoApply = mcpAutoApply
        self.mcpLogWorkouts = mcpLogWorkouts
        self.sex = sex
        self.birthYear = birthYear
    }

    /// A copy with the injury note and its end date replaced. The note is trimmed, and an empty note has no date.
    public func withLimits(_ note: String, until: Date?) -> Profile {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return Profile(unit: unit, restSec: restSec, warmupRestSec: warmupRestSec, heightCm: heightCm,
                       goalWeightKg: goalWeightKg, goalDate: goalDate, trainingDays: trainingDays,
                       experience: experience, limits: trimmed, limitsUntil: trimmed.isEmpty ? nil : until,
                       deloadPct: deloadPct, barKg: barKg, plateInventory: plateInventory,
                       dumbbellStepKg: dumbbellStepKg, mcpReadWorkouts: mcpReadWorkouts, mcpReadBody: mcpReadBody,
                       mcpReadPlan: mcpReadPlan, mcpReadGyms: mcpReadGyms, mcpPropose: mcpPropose,
                       mcpAutoApply: mcpAutoApply, mcpLogWorkouts: mcpLogWorkouts, sex: sex, birthYear: birthYear)
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
