import GymCore

/// Best-effort body part / equipment / mode for a custom exercise created from a Fitbod name. The user can edit
/// these later; they only need to be sensible for filtering and logging.
enum ImportedExerciseTraits {
    /// Cardio when any set carries a duration or distance and no reps (e.g. Swimming), otherwise weight × reps.
    static func mode(for sets: [ImportedSet]) -> ExerciseMode {
        sets.contains { ($0.durationSec != nil || $0.distanceM != nil) && $0.reps == 0 } ? .cardio : .reps
    }

    private static let equipmentKeywords: [(String, String)] = [
        ("handle band", "band"), ("band", "band"), ("barbell", "barbell"), ("ez bar", "ez barbell"),
        ("dumbbell", "dumbbell"), ("kettlebell", "kettlebell"), ("cable", "cable"), ("smith", "smith machine"),
        ("machine", "leverage machine")
    ]

    private static let bodyPartKeywords: [(String, String)] = [
        ("calf", "lower legs"), ("curl", "upper arms"), ("tricep", "upper arms"), ("dip", "upper arms"),
        ("row", "back"), ("pulldown", "back"), ("pull", "back"), ("superman", "back"),
        ("squat", "upper legs"), ("lunge", "upper legs"), ("glute", "upper legs"), ("hip", "upper legs"),
        ("clam", "upper legs"), ("kickback", "upper legs"), ("deadlift", "upper legs"), ("leg", "upper legs"),
        ("shoulder", "shoulders"), ("raise", "shoulders"), ("delt", "shoulders"), ("halo", "shoulders"),
        ("fly", "chest"), ("push", "chest"), ("press", "chest"),
        ("crunch", "waist"), ("twist", "waist"), ("plank", "waist"), ("toe", "waist")
    ]

    static func equipment(for name: String) -> String {
        match(name, in: equipmentKeywords) ?? "body weight"
    }

    static func bodyPart(for name: String) -> String {
        match(name, in: bodyPartKeywords) ?? "waist"
    }

    private static func match(_ name: String, in table: [(String, String)]) -> String? {
        let normalized = " " + ExerciseMatcher.normalize(name) + " "
        return table.first { normalized.contains(" " + $0.0) }?.1
    }
}
