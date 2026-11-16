/// The kinds of outside workout GymRollins names (plan 39). The slug is what's stored and synced; `HealthKitStore`
/// maps each `HKWorkoutActivityType` to one, and any other type is `other`.
public enum OutsideWorkoutKind: String, CaseIterable, Sendable {
    case walking, running, cycling, hiit, yoga, swimming
    case traditionalStrength = "traditional_strength", functionalStrength = "functional_strength"
    case elliptical, rowing, hiking, dance, core, pilates, cooldown, stairs
    case jumpRope = "jump_rope", mixedCardio = "mixed_cardio", crossTraining = "cross_training"
    case flexibility, mindAndBody = "mind_and_body", tennis, soccer, basketball, boxing, kickboxing
    case martialArts = "martial_arts", climbing, skiing, snowboarding, golf, other

    /// The kind a stored slug names; `other` for one this version doesn't know.
    public init(slug: String) {
        self = Self(rawValue: slug) ?? .other
    }

    public var title: String {
        switch self {
        case .walking: "Walk"
        case .running: "Run"
        case .cycling: "Cycling"
        case .hiit: "HIIT"
        case .yoga: "Yoga"
        case .swimming: "Swim"
        case .traditionalStrength: "Traditional Strength Training"
        case .functionalStrength: "Functional Strength Training"
        case .elliptical: "Elliptical"
        case .rowing: "Rowing"
        case .hiking: "Hike"
        case .dance: "Dance"
        case .core: "Core Training"
        case .pilates: "Pilates"
        case .cooldown: "Cooldown"
        case .stairs: "Stair Stepper"
        case .jumpRope: "Jump Rope"
        case .mixedCardio: "Mixed Cardio"
        case .crossTraining: "Cross Training"
        case .flexibility: "Flexibility"
        case .mindAndBody: "Mind and Body"
        case .tennis: "Tennis"
        case .soccer: "Soccer"
        case .basketball: "Basketball"
        case .boxing: "Boxing"
        case .kickboxing: "Kickboxing"
        case .martialArts: "Martial Arts"
        case .climbing: "Climbing"
        case .skiing: "Skiing"
        case .snowboarding: "Snowboarding"
        case .golf: "Golf"
        case .other: "Workout"
        }
    }

    /// The SF Symbol shown beside it.
    public var symbol: String {
        switch self {
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .cycling: "figure.outdoor.cycle"
        case .hiit: "figure.highintensity.intervaltraining"
        case .yoga: "figure.yoga"
        case .swimming: "figure.pool.swim"
        case .traditionalStrength: "figure.strengthtraining.traditional"
        case .functionalStrength: "figure.strengthtraining.functional"
        case .elliptical: "figure.elliptical"
        case .rowing: "figure.rower"
        case .hiking: "figure.hiking"
        case .dance: "figure.dance"
        case .core: "figure.core.training"
        case .pilates: "figure.pilates"
        case .cooldown: "figure.cooldown"
        case .stairs: "figure.stair.stepper"
        case .jumpRope: "figure.jumprope"
        case .mixedCardio, .other: "figure.mixed.cardio"
        case .crossTraining: "figure.cross.training"
        case .flexibility: "figure.flexibility"
        case .mindAndBody: "figure.mind.and.body"
        case .tennis: "figure.tennis"
        case .soccer: "figure.soccer"
        case .basketball: "figure.basketball"
        case .boxing: "figure.boxing"
        case .kickboxing: "figure.kickboxing"
        case .martialArts: "figure.martial.arts"
        case .climbing: "figure.climbing"
        case .skiing: "figure.skiing.downhill"
        case .snowboarding: "figure.snowboarding"
        case .golf: "figure.golf"
        }
    }
}
