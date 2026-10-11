import Foundation
import GymCore
import SwiftData

@MainActor
public final class ProfileRepository {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    public func load() throws -> Profile {
        guard let r = try record() else { return Profile() }
        let unit = WeightUnit(rawValue: r.unitRaw) ?? .lb
        return Profile(unit: unit, restSec: r.restSec, warmupRestSec: r.warmupRestSec,
                       heightCm: r.heightCm, goalWeightKg: r.goalWeightKg, goalDate: r.goalDate,
                       trainingDays: r.trainingDays, experience: r.experience, limits: r.limits,
                       deloadPct: r.deloadPct, barKg: r.barKg,
                       plateInventory: PlateInventory(unit: unit,
                                                      bar: UnitConverter.fromKg(r.barKg, to: unit).rounded(toPlaces: 2),
                                                      plates: r.platesKg.map { UnitConverter.fromKg($0, to: unit).rounded(toPlaces: 2) }),
                       dumbbellStepKg: r.dumbbellStepKg, mcpReadWorkouts: r.mcpReadWorkouts, mcpReadBody: r.mcpReadBody,
                       mcpReadPlan: r.mcpReadPlan, mcpPropose: r.mcpPropose, mcpAutoApply: r.mcpAutoApply,
                       sex: r.sexRaw.flatMap(ProfileSex.init(rawValue:)), birthYear: r.birthYear)
    }

    public func save(_ p: Profile) throws {
        if let violation = DomainLimits.profileViolation(
            restSec: p.restSec, warmupRestSec: p.warmupRestSec, heightCm: p.heightCm, goalWeightKg: p.goalWeightKg,
            trainingDays: p.trainingDays, limits: p.limits, deloadPct: p.deloadPct) {
            throw GymDataError.invalidInput(violation)
        }
        let r = try record() ?? {
            let new = ProfileRecord(now: now())
            context.insert(new)
            return new
        }()
        r.unitRaw = p.unit.rawValue
        r.restSec = p.restSec
        r.warmupRestSec = p.warmupRestSec
        r.heightCm = p.heightCm
        r.goalWeightKg = p.goalWeightKg
        r.goalDate = p.goalDate
        r.trainingDays = p.trainingDays
        r.experience = p.experience
        r.limits = p.limits
        r.deloadPct = p.deloadPct
        // The inventory's bar is what the plate calculator shows; persist it (in kg) so `barKg` and the reloaded
        // inventory can never disagree (e.g. a kg inventory saved next to the default 45 lb `barKg`).
        r.barKg = UnitConverter.toKg(p.plateInventory.bar, from: p.plateInventory.unit)
        r.platesKg = p.plateInventory.plates.map { UnitConverter.toKg($0, from: p.plateInventory.unit) }
        r.dumbbellStepKg = p.dumbbellStepKg
        r.mcpReadWorkouts = p.mcpReadWorkouts
        r.mcpReadBody = p.mcpReadBody
        r.mcpReadPlan = p.mcpReadPlan
        r.mcpPropose = p.mcpPropose
        r.mcpAutoApply = p.mcpAutoApply
        r.updatedAt = now()
        r.dirty = true
        try context.save()
    }

    /// Sets (or clears, with nil) the strength-level inputs, creating the profile if needed. The only writer of
    /// `sex` and `birthYear`: `save(_:)` leaves them alone.
    public func setStrengthProfile(sex: ProfileSex?, birthYear: Int?) throws {
        if let birthYear, !DomainLimits.birthYear.contains(birthYear) {
            throw GymDataError.invalidInput("Birth year must be \(DomainLimits.birthYear.lowerBound)–"
                                            + "\(DomainLimits.birthYear.upperBound).")
        }
        let r = try record() ?? {
            let new = ProfileRecord(now: now())
            context.insert(new)
            return new
        }()
        r.sexRaw = sex?.rawValue
        r.birthYear = birthYear
        r.updatedAt = now()
        r.dirty = true
        try context.save()
    }

    /// Updates only Claude's permissions (no other field is rewritten), creating the profile if needed.
    public func setMcpPermissions(readWorkouts: Bool, readBody: Bool, readPlan: Bool, propose: Bool,
                                  autoApply: Bool) throws {
        let r = try record() ?? {
            let new = ProfileRecord(now: now())
            context.insert(new)
            return new
        }()
        r.mcpReadWorkouts = readWorkouts
        r.mcpReadBody = readBody
        r.mcpReadPlan = readPlan
        r.mcpPropose = propose
        r.mcpAutoApply = autoApply
        r.updatedAt = now()
        r.dirty = true
        try context.save()
    }

    private func record() throws -> ProfileRecord? {
        let id = ProfileRecord.singletonID
        return try context.fetch(FetchDescriptor<ProfileRecord>(predicate: #Predicate { $0.id == id })).first
    }
}
