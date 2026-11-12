public enum WarmupGenerator {
    /// Bar x10, then ~75% x5 when the working weight is well above the bar. The ramp is the rounder's, so in lb it
    /// has the grid's pound number; the bar is the profile's bar weight, which has none.
    public static func sets(workingKg: Double, barKg: Double, rounder: LoadRounder) -> [WorkoutSet] {
        guard workingKg > barKg + 0.01 else { return [] }
        let bar = WorkoutSet(weightKg: barKg, reps: 10, warmup: true)
        guard workingKg > barKg * 1.5 else { return [bar] }
        let ramp = rounder.nearestWeight(workingKg * 0.75)
        return [bar, WorkoutSet(weightKg: ramp.kg, weightLb: ramp.lb, reps: 5, warmup: true)]
    }
}
