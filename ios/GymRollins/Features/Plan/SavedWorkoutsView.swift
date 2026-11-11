import GymCore
import GymData
import SwiftUI

/// Every saved workout, on the week or not (Switch and the rest-day suggestion pick from these), paused ones included,
/// and "+ Workout". Each row says which days it's on.
struct SavedWorkoutsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var routines: [Routine] = []
    @State private var schedule = WeekSchedule(days: [:])
    @State private var editing: Routine?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DisplayTitle(text: "Saved workouts")
                ForEach(routines) { routine in
                    Button { editing = routine } label: { row(routine) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("plan.routine.\(routine.name)")
                }
                GlassPillButton(title: "+ Workout", identifier: "plan.addRoutine") {
                    editing = env.newRoutineDraft()
                }
                if let error { Text(error).foregroundStyle(Theme.destructive) }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing, onDismiss: reload) { RoutineEditView(routine: $0) }
        .task(id: env.planRevision) { reload() }
    }

    private func row(_ routine: Routine) -> some View {
        let days = WeekPlan.weekdays(of: routine.id, in: schedule)
        let count = routine.exercises.count == 1 ? "1 exercise" : "\(routine.exercises.count) exercises"
        let on = days.isEmpty ? "not on your week" : days.map { WeekPlan.shortDayName($0) }.joined(separator: ", ")
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.name).font(.headline).foregroundStyle(Theme.textPrimary)
                Text("\(count) \u{00B7} \(on)").font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if routine.paused { Badge(text: "Paused", kind: .record) }
            Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
        }
        .padding(14)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        .opacity(routine.paused ? 0.7 : 1)
    }

    private func reload() {
        do { routines = try env.routines.all(); schedule = try env.routines.schedule(); error = nil }
        catch { self.error = "Couldn't load your workouts." }
    }
}
