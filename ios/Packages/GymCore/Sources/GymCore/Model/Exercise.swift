public enum ExerciseMode: String, Codable, Sendable, CaseIterable {
    case reps, time, cardio
}

/// Library or custom exercise. JSON keys follow opengym's compact shape (n, bp, eq, tg, sm, st).
public struct Exercise: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let bodyPart: String
    public let equipment: String
    public let target: String
    public let secondary: [String]
    public let instructions: [String]
    public let image: String?
    public let gif: String?
    public let aliases: [String]
    public let isCustom: Bool
    public let mode: ExerciseMode
    public let muscleGroup: String?
    /// True when the exercise works both sides together (e.g. barbell bench press), as opposed to
    /// one side at a time (e.g. single-arm dumbbell row).
    public let bilateral: Bool

    public init(id: String, name: String, bodyPart: String, equipment: String, target: String,
                secondary: [String] = [], instructions: [String] = [], image: String? = nil, gif: String? = nil,
                aliases: [String] = [], isCustom: Bool = false, mode: ExerciseMode? = nil,
                muscleGroup: String? = nil, bilateral: Bool = false) {
        self.id = id
        self.name = name
        self.bodyPart = bodyPart
        self.equipment = equipment
        self.target = target
        self.secondary = secondary
        self.instructions = instructions
        self.image = image
        self.gif = gif
        self.aliases = aliases
        self.isCustom = isCustom
        self.mode = mode ?? (bodyPart == "cardio" ? .cardio : .reps)
        self.muscleGroup = muscleGroup
        self.bilateral = bilateral
    }

    enum CodingKeys: String, CodingKey {
        case id, n, bp, eq, tg, sm, st, img, gif, aliases, custom, mode, mg, bilateral
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .n),
            bodyPart: try c.decode(String.self, forKey: .bp),
            equipment: try c.decode(String.self, forKey: .eq),
            target: try c.decode(String.self, forKey: .tg),
            secondary: try c.decodeIfPresent([String].self, forKey: .sm) ?? [],
            instructions: try c.decodeIfPresent([String].self, forKey: .st) ?? [],
            image: try c.decodeIfPresent(String.self, forKey: .img),
            gif: try c.decodeIfPresent(String.self, forKey: .gif),
            aliases: try c.decodeIfPresent([String].self, forKey: .aliases) ?? [],
            isCustom: try c.decodeIfPresent(Bool.self, forKey: .custom) ?? false,
            mode: try c.decodeIfPresent(ExerciseMode.self, forKey: .mode),
            muscleGroup: try c.decodeIfPresent(String.self, forKey: .mg),
            bilateral: try c.decodeIfPresent(Bool.self, forKey: .bilateral) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .n)
        try c.encode(bodyPart, forKey: .bp)
        try c.encode(equipment, forKey: .eq)
        try c.encode(target, forKey: .tg)
        try c.encode(secondary, forKey: .sm)
        try c.encode(instructions, forKey: .st)
        try c.encodeIfPresent(image, forKey: .img)
        try c.encodeIfPresent(gif, forKey: .gif)
        try c.encode(aliases, forKey: .aliases)
        try c.encode(isCustom, forKey: .custom)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(muscleGroup, forKey: .mg)
        try c.encode(bilateral, forKey: .bilateral)
    }
}
