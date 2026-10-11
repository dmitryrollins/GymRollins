import GymCore
import SwiftUI

/// Settings → Weekly targets: a min/max hard-set range per muscle group (defaults 10–20 major, 6–12 small).
struct WeeklyTargetsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var targets = MuscleGroup.defaultTargets
    @State private var error: String?
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Text("Hard sets per muscle per week (Monday\u{2013}Sunday). Warm-ups don't count; an exercise's "
                     + "secondary muscles count half a set.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            Section("Major groups") { ForEach(MuscleGroup.allCases.filter(\.isMajor)) { row($0) } }
            Section("Smaller groups") { ForEach(MuscleGroup.allCases.filter { !$0.isMajor }) { row($0) } }
            if let error {
                Section { Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("targets.error") }
            }
            Section {
                Button("Reset to Defaults", role: .destructive) { confirmReset = true }
                    .accessibilityIdentifier("targets.reset")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Weekly Targets")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        .task(id: env.dataRevision) { load() }
        .confirmationDialog("Reset every weekly target to its default?", isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button("Reset", role: .destructive) { reset() }.accessibilityIdentifier("targets.reset.confirm")
        }
    }

    private func row(_ group: MuscleGroup) -> some View {
        let range = targets[group] ?? group.defaultTarget
        let limit = DomainLimits.weeklySetTarget
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(group.displayName).font(.body.weight(.semibold))
                Spacer()
                Text("\(range.text) sets").foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("targets.value.\(group.rawValue)")
            }
            Stepper("Min \(range.min)", value: binding(group, \.min), in: limit.lowerBound...range.max)
                .accessibilityLabel("\(group.displayName) minimum")
                .accessibilityValue("\(range.min) sets")
                .accessibilityIdentifier("targets.min.\(group.rawValue)")
            Stepper("Max \(range.max)", value: binding(group, \.max), in: range.min...limit.upperBound)
                .accessibilityLabel("\(group.displayName) maximum")
                .accessibilityValue("\(range.max) sets")
                .accessibilityIdentifier("targets.max.\(group.rawValue)")
        }
        .padding(.vertical, 2)
    }

    private func binding(_ group: MuscleGroup, _ end: KeyPath<SetTargetRange, Int>) -> Binding<Int> {
        Binding(get: { (targets[group] ?? group.defaultTarget)[keyPath: end] }, set: { value in
            let current = targets[group] ?? group.defaultTarget
            let updated = end == \SetTargetRange.min ? SetTargetRange(min: value, max: current.max)
                : SetTargetRange(min: current.min, max: value)
            save(group, updated)
        })
    }

    private func load() {
        do {
            targets = try env.muscleTargets.all()
        } catch {
            AppEnvironment.log.error("Load targets failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't load your targets."
        }
    }

    private func save(_ group: MuscleGroup, _ range: SetTargetRange) {
        do {
            try env.setMuscleTarget(group, range)
            targets = targets.merging([group: range]) { $1 }
            error = nil
        } catch {
            AppEnvironment.log.error("Save target failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save. Targets are 0\u{2013}50 sets with the minimum at or below the maximum."
        }
    }

    private func reset() {
        do {
            try env.resetMuscleTargets()
            load()
        } catch {
            AppEnvironment.log.error("Reset targets failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't reset. Please try again."
        }
    }
}
