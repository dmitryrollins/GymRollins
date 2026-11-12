import GymCore
import SwiftUI

/// A workout's exercises in an editor's list: sets, reps and weight steppers per row, reorder and delete, and
/// "+ Add exercise" (the parent shows the picker). Used by Saved workouts' editor and My Plan's day editor.
struct RoutineExercisesSection: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var items: [RoutineExercise]
    @Binding var showPicker: Bool

    var body: some View {
        Section("Exercises") {
            ForEach(items) { item in row(item) }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { items.remove(atOffsets: $0) }
            Button("+ Add exercise") { showPicker = true }
                .disabled(items.count >= DomainLimits.routineExercisesMax)
                .accessibilityIdentifier("edit.addExercise")
        }
    }

    private func row(_ item: RoutineExercise) -> some View {
        let ex = env.library.exercise(item.exerciseId)
        // The row identifier is placed on the name label rather than the enclosing VStack:
        // an accessibilityIdentifier applied to a container overrides (rather than merely
        // labels) every accessibility element nested inside it, which would otherwise stomp
        // the Steppers' own edit.sets/edit.reps/edit.weight identifiers below.
        return VStack(alignment: .leading, spacing: 6) {
            Text(DisplayName.of(ex?.name ?? item.exerciseId)).font(.headline)
                .accessibilityIdentifier("edit.row.\(item.exerciseId)")
            Stepper("\(item.sets) sets", value: binding(item, \.sets, 1...10))
                .accessibilityIdentifier("edit.sets.\(item.exerciseId)")
            Stepper("\(item.repsMin.map { "\($0)\u{2013}" } ?? "")\(item.reps) reps", value: binding(item, \.reps, 1...50))
                .accessibilityIdentifier("edit.reps.\(item.exerciseId)")
            Stepper(item.weight.map { WeightFormatter.format(kg: $0.kg, lb: $0.lb, unit: env.profile.unit) }
                        ?? "Bodyweight",
                    value: weightBinding(item), step: 1)
                .accessibilityIdentifier("edit.weight.\(item.exerciseId)")
        }
    }

    /// Returns a binding that rebuilds the immutable RoutineExercise on change.
    private func binding(_ item: RoutineExercise, _ key: KeyPath<RoutineExercise, Int>,
                         _ range: ClosedRange<Int>) -> Binding<Int> {
        Binding(get: { item[keyPath: key] }, set: { newValue in
            let v = min(max(newValue, range.lowerBound), range.upperBound)
            replace(item, sets: key == \.sets ? v : item.sets, reps: key == \.reps ? v : item.reps, weight: item.weight)
        })
    }

    /// Weight stepper moves one loadable increment in the user's unit. The step lands on the rounder's grid, so in lb
    /// the new weight has the grid's pound number (plan 38).
    private func weightBinding(_ item: RoutineExercise) -> Binding<Double> {
        let rounder = LoadRounding.rounder(for: env.library.exercise(item.exerciseId), profile: env.profile)
        let stepKg = UnitConverter.toKg(rounder.step, from: rounder.unit)
        return Binding(get: { (item.weightKg ?? 0) / stepKg }, set: { steps in
            let weight = rounder.nearestWeight(steps.rounded() * stepKg)
            replace(item, sets: item.sets, reps: item.reps, weight: weight.kg > 0 ? weight : nil)
        })
    }

    private func replace(_ item: RoutineExercise, sets: Int, reps: Int, weight: PoundWeight?) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let weightChanged = abs((weight?.kg ?? 0) - (item.weightKg ?? 0)) > 0.001
        items[index] = RoutineExercise(id: item.id, exerciseId: item.exerciseId, sets: sets, reps: reps,
                                       repsMin: item.repsMin.map { min($0, reps) }, sec: item.sec,
                                       weightKg: weight?.kg, weightLb: weight?.lb,
                                       mode: item.mode, policy: item.policy, incKg: item.incKg,
                                       supersetGroup: item.supersetGroup,
                                       weightSetAt: weightChanged ? env.now() : item.weightSetAt)
    }
}
