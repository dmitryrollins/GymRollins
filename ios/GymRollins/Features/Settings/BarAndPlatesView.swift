import GymCore
import GymData
import SwiftUI

/// Bar weight, which of the unit's standard plates are on hand (toggled per size), and the dumbbell step —
/// all in the profile's current unit; storage stays kg (`ProfileRepository` converts).
struct BarAndPlatesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var form = BarAndPlatesForm(barText: "", dumbbellStepText: "", available: [])
    @State private var error: String?
    @State private var loaded = false

    private var unit: WeightUnit { env.profile.unit }
    private var standardPlates: [Double] { BarAndPlatesForm.standardPlates(unit) }

    var body: some View {
        Form {
            Section("Bar") {
                TextField("Bar weight (\(unit.rawValue))", text: $form.barText)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("settings.bar.weight")
            }
            Section("Plates available per side") {
                ForEach(standardPlates, id: \.self) { plate in
                    Toggle("\(BarAndPlatesForm.format(plate)) \(unit.rawValue)", isOn: binding(for: plate))
                        .accessibilityIdentifier("settings.plates.\(WeightFormatter.number(plate))")
                }
            }
            Section("Dumbbells") {
                TextField("Step (\(unit.rawValue))", text: $form.dumbbellStepText)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("settings.dumbbell.step")
            }
            if let error {
                Section { Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("settings.plates.error") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Bar & Plates")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        .task { load() }
        .onChange(of: form) { _, _ in save() }
    }

    private func binding(for plate: Double) -> Binding<Bool> {
        Binding(get: { form.available.contains(plate) }, set: { on in
            if on { form.available.insert(plate) } else { form.available.remove(plate) }
        })
    }

    private func load() {
        guard !loaded else { return }
        form = BarAndPlatesForm(profile: env.profile)
        loaded = true
    }

    /// Saves only real edits: loading the fields (or retyping the same value) writes nothing.
    private func save() {
        guard loaded else { return }
        do {
            guard let updated = try form.updatedProfile(from: env.profile) else {
                error = nil
                return
            }
            try env.profiles.save(updated)
            env.reloadProfile()
            env.planChanged()
            error = nil
        } catch is BarAndPlatesForm.Invalid {
            error = "Enter a bar weight and dumbbell step greater than zero."
        } catch {
            AppEnvironment.log.error("Save bar/plates failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save. Please try again."
        }
    }
}
