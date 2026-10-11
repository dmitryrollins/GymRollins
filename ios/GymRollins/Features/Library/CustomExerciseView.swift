import GymCore
import SwiftUI

struct CustomExerciseView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var bodyPart = "chest"
    @State private var equipment = "dumbbell"
    @State private var mode: ExerciseMode = .reps
    @State private var bilateral = false
    @State private var error: String?

    /// `prefillName` seeds the name field, e.g. from the Library's "No exercises match '<q>'" empty state.
    init(prefillName: String = "") {
        _name = State(initialValue: prefillName)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name).accessibilityIdentifier("custom.name")
                    .onChange(of: name) { _, new in
                        if new.count > DomainLimits.customExerciseNameMax {
                            name = String(new.prefix(DomainLimits.customExerciseNameMax))
                        }
                    }
                Picker("Body part", selection: $bodyPart) {
                    ForEach(env.library.bodyParts, id: \.self) { Text(DisplayName.of($0)).tag($0) }
                }
                Picker("Equipment", selection: $equipment) {
                    ForEach(env.library.equipment, id: \.self) { Text(DisplayName.of($0)).tag($0) }
                }
                Picker("Logging", selection: $mode) {
                    Text("Weight \u{00D7} reps").tag(ExerciseMode.reps)
                    Text("Time").tag(ExerciseMode.time)
                    Text("Cardio").tag(ExerciseMode.cardio)
                }
                .pickerStyle(.segmented)
                Toggle("Uses both dumbbells (count weight \u{00D7} 2 for volume)", isOn: $bilateral)
                if let error { Text(error).foregroundStyle(Theme.destructive) }
            }
            .navigationTitle("New Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(DomainLimits.customExerciseNameViolation(name) != nil)
                        .accessibilityIdentifier("custom.save")
                }
            }
        }
    }

    private func save() {
        if let violation = DomainLimits.customExerciseNameViolation(name) { error = violation; return }
        do {
            try env.customExercises.create(name: name, bodyPart: bodyPart, equipment: equipment, target: bodyPart,
                                           mode: mode, bilateral: bilateral)
            env.libraryChanged()
            dismiss()
        } catch {
            AppEnvironment.log.error("Create exercise failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save the exercise. Try again."
        }
    }
}
