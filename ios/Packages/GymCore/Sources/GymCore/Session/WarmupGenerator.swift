public enum WarmupGenerator {
    /// Bar x10, then ~75% x5 when the working weight is well above the bar.
    public static func sets(workingKg: Double, barKg: Double, rounder: LoadRounder) -> [WorkoutSet] {
        guard workingKg > barKg + 0.01 else { return [] }
        let bar = WorkoutSet(weightKg: barKg, reps: 10, warmup: true)
        guard workingKg > barKg * 1.5 else { return [bar] }
        let ramp = WorkoutSet(weightKg: rounder.nearest(workingKg * 0.75), reps: 5, warmup: true)
        return [bar, ramp]
    }
}
