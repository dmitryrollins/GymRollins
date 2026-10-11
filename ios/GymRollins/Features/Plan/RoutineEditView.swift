import GymCore
import SwiftUI

struct RoutineEditView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let routine: Routine
    @State private var name: String
    @State private var paused: Bool
    @State private var items: [RoutineExercise]
    @State private var showPicker = false
    @State private var error: String?

    init(routine: Routine) {
        self.routine = routine
        _name = State(initialValue: routine.name)
        _paused = State(initialValue: routine.paused)
        _items = State(initialValue: routine.exercises)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Routine name", text: $name).accessibilityIdentifier("edit.name")
                        .onChange(of: name) { _, new in
                            if new.count > DomainLimits.routineNameMax {
                                name = String(new.prefix(DomainLimits.routineNameMax))
                            }
                        }
                    Toggle("Paused", isOn: $paused)
                }
                Section("Exercises") {
                    ForEach(items) { item in row(item) }
                        .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { items.remove(atOffsets: $0) }
                    Button("+ Add exercise") { showPicker = true }
                        .disabled(items.count >= DomainLimits.routineExercisesMax)
                        .accessibilityIdentifier("edit.addExercise")
                }
                if let error {
                    Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("edit.error")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .environment(\.editMode, .constant(.active))
            .navigationTitle(name.isEmpty ? "Routine" : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save).buttonStyle(.glassProminent).tint(Theme.primaryFill)
                        .accessibilityIdentifier("edit.done")
                }
            }
            .sheet(isPresented: $showPicker) {
                ExercisePickerView(excluded: Set(items.map(\.exerciseId))) { ids in
                    items += ids.compactMap { env.library.exercise($0) }
                        .map { RoutineDefaults.item(for: $0, profile: env.profile) }
                }
            }
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
            Stepper(item.weightKg.map { WeightFormatter.format(kg: $0, unit: env.profile.unit) } ?? "Bodyweight",
                    value: weightBinding(item), step: 1)
                .accessibilityIdentifier("edit.weight.\(item.exerciseId)")
        }
    }

    /// Returns a binding that rebuilds the immutable RoutineExercise on change.
    private func binding(_ item: RoutineExercise, _ key: KeyPath<RoutineExercise, Int>,
                         _ range: ClosedRange<Int>) -> Binding<Int> {
        Binding(get: { item[keyPath: key] }, set: { newValue in
            let v = min(max(newValue, range.lowerBound), range.upperBound)
            replace(item, sets: key == \.sets ? v : item.sets, reps: key == \.reps ? v : item.reps, weightKg: item.weightKg)
        })
    }

    /// Weight stepper moves one loadable increment in the user's unit.
    private func weightBinding(_ item: RoutineExercise) -> Binding<Double> {
        let rounder = LoadRounding.rounder(for: env.library.exercise(item.exerciseId), profile: env.profile)
        let stepKg = UnitConverter.toKg(rounder.step, from: rounder.unit)
        return Binding(get: { (item.weightKg ?? 0) / stepKg }, set: { steps in
            let kg = max(0, rounder.nearest(steps.rounded() * stepKg))
            replace(item, sets: item.sets, reps: item.reps, weightKg: kg == 0 ? nil : kg)
        })
    }

    private func replace(_ item: RoutineExercise, sets: Int, reps: Int, weightKg: Double?) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let weightChanged = abs((weightKg ?? 0) - (item.weightKg ?? 0)) > 0.001
        items[index] = RoutineExercise(id: item.id, exerciseId: item.exerciseId, sets: sets, reps: reps,
                                       repsMin: item.repsMin.map { min($0, reps) }, sec: item.sec, weightKg: weightKg,
                                       mode: item.mode, policy: item.policy, incKg: item.incKg,
                                       supersetGroup: item.supersetGroup,
                                       weightSetAt: weightChanged ? env.now() : item.weightSetAt)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let edited = Routine(id: routine.id, name: trimmed, emoji: routine.emoji, policy: routine.policy,
                             paused: paused, exercises: items)
        if let violation = DomainLimits.routineViolation(edited) { error = violation; return }
        do {
            try env.routines.upsert(edited)
            env.planChanged()
            dismiss()
        } catch {
            AppEnvironment.log.error("Save routine failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save the routine. Try again."
        }
    }
}
