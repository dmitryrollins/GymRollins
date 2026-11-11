import GymCore
import GymData
import SwiftUI

/// A saved workout, opened from Saved workouts: its name, Paused, and its exercises. A change here reaches every day
/// the workout is on; one day is changed on its own from My Plan's week (`DayWorkoutEditView`).
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
                    TextField("Workout name", text: $name).accessibilityIdentifier("edit.name")
                        .onChange(of: name) { _, new in
                            if new.count > DomainLimits.routineNameMax {
                                name = String(new.prefix(DomainLimits.routineNameMax))
                            }
                        }
                    Toggle("Paused", isOn: $paused)
                }
                RoutineExercisesSection(items: $items, showPicker: $showPicker)
                if let error {
                    Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("edit.error")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .environment(\.editMode, .constant(.active))
            .navigationTitle(name.isEmpty ? "Workout" : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save).buttonStyle(.glassProminent).tint(Theme.primaryButtonFill)
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
            self.error = "Couldn't save the workout. Try again."
        }
    }
}
