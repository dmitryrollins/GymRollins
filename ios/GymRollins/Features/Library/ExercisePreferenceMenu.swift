import GymCore
import SwiftUI

/// Fitbod's exercise ··· items: "Recommend more often" / "Recommend less often" toggles (checkmark = current choice)
/// and "Don't recommend again", which asks first (`exercisePreferenceConfirmation`). Choosing a checked item again
/// goes back to normal. Put inside a `Menu`.
struct ExercisePreferenceMenuItems: View {
    @Environment(AppEnvironment.self) private var env
    let exerciseId: String
    /// Set to ask for "Don't recommend again" confirmation (the dialog lives on the screen, not in the menu).
    @Binding var confirmingNever: String?
    @Binding var error: String?

    var body: some View {
        let current = env.preference(for: exerciseId)
        Toggle("Recommend more often", systemImage: "arrow.up", isOn: binding(current, .more))
            .accessibilityIdentifier("pref.more")
        Toggle("Recommend less often", systemImage: "arrow.down", isOn: binding(current, .less))
            .accessibilityIdentifier("pref.less")
        Toggle("Don't recommend again", systemImage: "nosign", isOn: Binding(
            get: { current == .never },
            set: { on in
                if on { confirmingNever = exerciseId } else { set(.normal) }
            }))
            .accessibilityIdentifier("pref.never")
    }

    private func binding(_ current: ExercisePreference, _ choice: ExercisePreference) -> Binding<Bool> {
        Binding(get: { current == choice }, set: { _ in set(current.toggled(choice)) })
    }

    private func set(_ preference: ExercisePreference) {
        do { try env.setPreference(preference, for: exerciseId) } catch {
            AppEnvironment.log.error("Save preference failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save that. Try again."
        }
    }
}

extension View {
    /// The "Don't recommend again?" confirmation for `ExercisePreferenceMenuItems`.
    func exercisePreferenceConfirmation(_ exerciseId: Binding<String?>, error: Binding<String?>) -> some View {
        modifier(NeverConfirmation(exerciseId: exerciseId, error: error))
    }
}

private struct NeverConfirmation: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Binding var exerciseId: String?
    @Binding var error: String?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title, isPresented: Binding(get: { exerciseId != nil }, set: { if !$0 { exerciseId = nil } }),
            titleVisibility: .visible, presenting: exerciseId
        ) { id in
            Button("Don't Recommend Again", role: .destructive) {
                do { try env.setPreference(.never, for: id) } catch {
                    AppEnvironment.log.error("Save preference failed: \(error.localizedDescription, privacy: .public)")
                    self.error = "Couldn't save that. Try again."
                }
                exerciseId = nil
            }
            .accessibilityIdentifier("pref.never.confirm")
            Button("Cancel", role: .cancel) { exerciseId = nil }
        } message: { _ in
            Text("It won't be suggested when you replace or add exercises. Searching still finds it, and you can "
                 + "undo this in Settings \u{2192} Hidden Exercises.")
        }
    }

    private var title: String {
        let name = exerciseId.flatMap { env.library.exercise($0) }.map { DisplayName.of($0.name) } ?? "this exercise"
        return "Stop recommending \(name)?"
    }
}
