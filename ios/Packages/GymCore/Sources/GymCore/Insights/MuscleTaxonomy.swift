import Foundation

/// How much one exercise works one muscle group: primary (the library's target, weight 1) or secondary (its
/// secondary muscles, weight 0.5).
public struct MuscleContribution: Equatable, Sendable {
    public let group: MuscleGroup
    public let weight: Double
    public let isPrimary: Bool

    public init(group: MuscleGroup, weight: Double, isPrimary: Bool) {
        self.group = group
        self.weight = weight
        self.isPrimary = isPrimary
    }
}

/// Maps the exercise library's muscle strings (`tg` target, `sm` secondary muscles) onto `MuscleGroup`s.
/// Keep in sync with `supabase/functions/_shared/insights.ts` (the shared fixture `fixtures/insights.json` checks).
public enum MuscleTaxonomy {
    public static let primaryWeight = 1.0
    public static let secondaryWeight = 0.5

    /// Library target (`tg`) values.
    private static let targets: [String: [MuscleGroup]] = [
        "pectorals": [.chest], "serratus anterior": [.chest],
        "delts": [.shoulders],
        "traps": [.traps], "levator scapulae": [.traps],
        "upper back": [.upperBack],
        "lats": [.lats],
        "spine": [.lowerBack],
        "biceps": [.biceps], "triceps": [.triceps], "forearms": [.forearms],
        "abs": [.abs],
        "glutes": [.glutes], "quads": [.quads], "hamstrings": [.hamstrings], "calves": [.calves],
        "adductors": [.adductors], "abductors": [.abductors],
    ]

    /// Secondary-muscle (`sm`) names, also accepted as targets.
    private static let muscles: [String: MuscleGroup] = [
        "chest": .chest, "upper chest": .chest,
        "shoulders": .shoulders, "deltoids": .shoulders, "rear deltoids": .shoulders, "rotator cuff": .shoulders,
        "trapezius": .traps, "traps": .traps, "sternocleidomastoid": .traps,
        "upper back": .upperBack, "rhomboids": .upperBack, "back": .upperBack,
        "latissimus dorsi": .lats, "lats": .lats,
        "lower back": .lowerBack,
        "biceps": .biceps, "brachialis": .biceps,
        "triceps": .triceps,
        "forearms": .forearms, "wrists": .forearms, "wrist flexors": .forearms, "wrist extensors": .forearms,
        "grip muscles": .forearms, "hands": .forearms,
        "core": .abs, "obliques": .abs, "abdominals": .abs, "lower abs": .abs, "hip flexors": .abs,
        "glutes": .glutes,
        "quadriceps": .quads,
        "hamstrings": .hamstrings,
        "calves": .calves, "soleus": .calves, "ankles": .calves, "ankle stabilizers": .calves, "feet": .calves,
        "shins": .calves,
        "inner thighs": .adductors, "groin": .adductors,
    ]

    /// Body-part fallback for targets the tables don't know (custom exercises store their body part as target).
    private static let bodyParts: [String: [MuscleGroup]] = [
        "chest": [.chest], "back": [.lats, .upperBack], "shoulders": [.shoulders],
        "upper arms": [.biceps, .triceps], "lower arms": [.forearms],
        "upper legs": [.quads, .hamstrings, .glutes], "lower legs": [.calves], "waist": [.abs], "neck": [.traps],
    ]

    public static func groups(forTarget target: String) -> [MuscleGroup] {
        let key = normalize(target)
        if let groups = targets[key] { return groups }
        return muscles[key].map { [$0] } ?? []
    }

    public static func group(forMuscle muscle: String) -> MuscleGroup? { muscles[normalize(muscle)] }

    /// Primary groups first (target order), then secondary groups in the library's order; each group once, with
    /// primary winning. Cardio exercises work no group.
    public static func contributions(for exercise: Exercise) -> [MuscleContribution] {
        guard exercise.mode != .cardio else { return [] }
        var primary = groups(forTarget: exercise.target)
        if primary.isEmpty { primary = bodyParts[normalize(exercise.bodyPart)] ?? [] }
        let share = primary.isEmpty ? 0 : primaryWeight / Double(primary.count)
        var seen = Set(primary)
        var out = primary.map { MuscleContribution(group: $0, weight: share, isPrimary: true) }
        for muscle in exercise.secondary {
            guard let group = group(forMuscle: muscle), !seen.contains(group) else { continue }
            seen.insert(group)
            out.append(MuscleContribution(group: group, weight: secondaryWeight, isPrimary: false))
        }
        return out
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
