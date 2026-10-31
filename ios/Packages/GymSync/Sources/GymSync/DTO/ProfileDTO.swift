import Foundation
import GymCore
import GymData

/// `public.profiles` (one row per user; `user_id` defaults to `auth.uid()` and is never sent).
public struct ProfileDTO: Codable, Sendable, Equatable, ServerStamped {
    public let unit: String
    public let restSec: Int
    public let warmupRestSec: Int
    public let heightCm: Double?
    public let goalWeightKg: Double?
    /// Postgres `date`, `yyyy-MM-dd`.
    public let goalDate: String?
    public let trainingDays: Int
    public let experience: String
    public let limits: String
    public let deloadPct: Double
    public let barKg: Double
    public let platesKg: [Double]
    public let dumbbellStepKg: Double
    public let mcpReadWorkouts: Bool
    public let mcpReadBody: Bool
    public let mcpReadPlan: Bool
    public let mcpReadGyms: Bool
    public let mcpPropose: Bool
    public let mcpAutoApply: Bool
    /// `male` / `female` or null (strength levels only).
    public let sex: String?
    public let birthYear: Int?
    public let clientUpdatedAt: Date
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case unit, experience, limits
        case restSec = "rest_sec", warmupRestSec = "warmup_rest_sec", heightCm = "height_cm"
        case goalWeightKg = "goal_weight_kg", goalDate = "goal_date", trainingDays = "training_days"
        case deloadPct = "deload_pct", barKg = "bar_kg", platesKg = "plates_kg", dumbbellStepKg = "dumbbell_step_kg"
        case mcpReadWorkouts = "mcp_read_workouts", mcpReadBody = "mcp_read_body", mcpPropose = "mcp_propose"
        case mcpReadPlan = "mcp_read_plan", mcpReadGyms = "mcp_read_gyms"
        case sex, birthYear = "birth_year"
        case mcpAutoApply = "mcp_auto_apply", clientUpdatedAt = "client_updated_at", updatedAt = "updated_at"
    }

    /// Synthesized decoding, except that a row without `mcp_read_gyms` reads as on, the column's default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = try c.decode(String.self, forKey: .unit)
        restSec = try c.decode(Int.self, forKey: .restSec)
        warmupRestSec = try c.decode(Int.self, forKey: .warmupRestSec)
        heightCm = try c.decodeIfPresent(Double.self, forKey: .heightCm)
        goalWeightKg = try c.decodeIfPresent(Double.self, forKey: .goalWeightKg)
        goalDate = try c.decodeIfPresent(String.self, forKey: .goalDate)
        trainingDays = try c.decode(Int.self, forKey: .trainingDays)
        experience = try c.decode(String.self, forKey: .experience)
        limits = try c.decode(String.self, forKey: .limits)
        deloadPct = try c.decode(Double.self, forKey: .deloadPct)
        barKg = try c.decode(Double.self, forKey: .barKg)
        platesKg = try c.decode([Double].self, forKey: .platesKg)
        dumbbellStepKg = try c.decode(Double.self, forKey: .dumbbellStepKg)
        mcpReadWorkouts = try c.decode(Bool.self, forKey: .mcpReadWorkouts)
        mcpReadBody = try c.decode(Bool.self, forKey: .mcpReadBody)
        mcpReadPlan = try c.decode(Bool.self, forKey: .mcpReadPlan)
        mcpReadGyms = try c.decodeIfPresent(Bool.self, forKey: .mcpReadGyms) ?? true
        mcpPropose = try c.decode(Bool.self, forKey: .mcpPropose)
        mcpAutoApply = try c.decode(Bool.self, forKey: .mcpAutoApply)
        sex = try c.decodeIfPresent(String.self, forKey: .sex)
        birthYear = try c.decodeIfPresent(Int.self, forKey: .birthYear)
        clientUpdatedAt = try c.decode(Date.self, forKey: .clientUpdatedAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public init(_ row: SyncRow<ProfileSnapshot>) {
        let p = row.value
        unit = p.unit.rawValue
        restSec = p.restSec
        warmupRestSec = p.warmupRestSec
        heightCm = p.heightCm
        goalWeightKg = p.goalWeightKg
        goalDate = p.goalDate.map { SyncDay.format($0) }
        trainingDays = p.trainingDays
        experience = p.experience
        limits = p.limits
        deloadPct = p.deloadPct
        barKg = p.barKg
        platesKg = p.platesKg
        dumbbellStepKg = p.dumbbellStepKg
        mcpReadWorkouts = p.mcpReadWorkouts
        mcpReadBody = p.mcpReadBody
        mcpReadPlan = p.mcpReadPlan
        mcpReadGyms = p.mcpReadGyms
        mcpPropose = p.mcpPropose
        mcpAutoApply = p.mcpAutoApply
        sex = p.sex?.rawValue
        birthYear = p.birthYear
        clientUpdatedAt = row.clientUpdatedAt
        updatedAt = row.serverUpdatedAt
    }

    public func toDomain() -> SyncRow<ProfileSnapshot> {
        var p = ProfileSnapshot()
        p.unit = WeightUnit(rawValue: unit) ?? .lb
        p.restSec = restSec
        p.warmupRestSec = warmupRestSec
        p.heightCm = heightCm
        p.goalWeightKg = goalWeightKg
        p.goalDate = goalDate.flatMap { SyncDay.parse($0) }
        p.trainingDays = trainingDays
        p.experience = experience
        p.limits = limits
        p.deloadPct = deloadPct
        p.barKg = barKg
        p.platesKg = platesKg
        p.dumbbellStepKg = dumbbellStepKg
        p.mcpReadWorkouts = mcpReadWorkouts
        p.mcpReadBody = mcpReadBody
        p.mcpReadPlan = mcpReadPlan
        p.mcpReadGyms = mcpReadGyms
        p.mcpPropose = mcpPropose
        p.mcpAutoApply = mcpAutoApply
        p.sex = sex.flatMap(ProfileSex.init(rawValue:))
        p.birthYear = birthYear
        return SyncRow(value: p, clientUpdatedAt: clientUpdatedAt, serverUpdatedAt: updatedAt)
    }

    /// Nulls are written explicitly so clearing a field on the device clears it on the server; `updated_at` is
    /// server-owned and never sent.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(unit, forKey: .unit)
        try c.encode(restSec, forKey: .restSec)
        try c.encode(warmupRestSec, forKey: .warmupRestSec)
        try c.encode(heightCm, forKey: .heightCm)
        try c.encode(goalWeightKg, forKey: .goalWeightKg)
        try c.encode(goalDate, forKey: .goalDate)
        try c.encode(trainingDays, forKey: .trainingDays)
        try c.encode(experience, forKey: .experience)
        try c.encode(limits, forKey: .limits)
        try c.encode(deloadPct, forKey: .deloadPct)
        try c.encode(barKg, forKey: .barKg)
        try c.encode(platesKg, forKey: .platesKg)
        try c.encode(dumbbellStepKg, forKey: .dumbbellStepKg)
        try c.encode(mcpReadWorkouts, forKey: .mcpReadWorkouts)
        try c.encode(mcpReadBody, forKey: .mcpReadBody)
        try c.encode(mcpReadPlan, forKey: .mcpReadPlan)
        try c.encode(mcpReadGyms, forKey: .mcpReadGyms)
        try c.encode(mcpPropose, forKey: .mcpPropose)
        try c.encode(mcpAutoApply, forKey: .mcpAutoApply)
        try c.encode(sex, forKey: .sex)
        try c.encode(birthYear, forKey: .birthYear)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}
