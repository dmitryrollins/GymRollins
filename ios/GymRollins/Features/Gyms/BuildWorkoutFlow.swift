import GymCore
import GymData
import SwiftUI

/// Today's "Build workout": the Build sheet, preceded by the gym picker when no gym is chosen. Setting `requested`
/// starts it. Start on the result closes the sheet first, and only then calls `onStart`, so the workout can present.
struct BuildWorkoutFlow: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Binding var requested: Bool
    let onStart: (_ name: String, _ items: [RoutineExercise]) -> Void
    @State private var showBuild = false
    @State private var showPicker = false
    @State private var afterPicker = false
    @State private var pending: (name: String, items: [RoutineExercise])?

    func body(content: Content) -> some View {
        content
            .onChange(of: requested) { _, isRequested in
                guard isRequested else { return }
                requested = false
                if env.currentGym != nil {
                    showBuild = true
                } else {
                    afterPicker = true
                    showPicker = true
                }
            }
            .sheet(isPresented: $showBuild, onDismiss: startPending) {
                if let gym = env.currentGym {
                    BuildWorkoutSheet(gym: gym) { name, items in
                        pending = (name, items)
                        showBuild = false
                    }
                }
            }
            .sheet(isPresented: $showPicker, onDismiss: openBuild) { GymPickerView() }
    }

    /// The picker closed: Build opens when it was chosen for, and a gym is now current.
    private func openBuild() {
        let continuing = afterPicker
        afterPicker = false
        if continuing, env.currentGym != nil { showBuild = true }
    }

    private func startPending() {
        guard let built = pending else { return }
        pending = nil
        onStart(built.name, built.items)
    }
}

extension View {
    func buildWorkoutFlow(requested: Binding<Bool>,
                          onStart: @escaping (_ name: String, _ items: [RoutineExercise]) -> Void) -> some View {
        modifier(BuildWorkoutFlow(requested: requested, onStart: onStart))
    }
}
