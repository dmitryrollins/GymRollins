import GymCore
import GymData
import SwiftUI

/// Today's Switch, on today or a later day: the saved workouts, and an empty workout (Rest on a later day). Picking the
/// day's own workout is the plan as scheduled; any other pick asks where it goes (owner, 2026-11-10): only this date,
/// or every week on this weekday. A paused workout can't go on the week, so it is this date only.
struct TodaySwitchSheet: View {
    enum Scope { case thisDay, everyWeek }

    /// A pick waiting for its scope (no workout: an empty workout, or Rest).
    struct Pick: Identifiable {
        let routine: Routine?
        var id: UUID? { routine?.id }
    }

    let routines: [Routine]
    /// The workout the day shows now (checkmarked).
    let current: UUID?
    /// The workout the week has on this day (nil: a rest day).
    let scheduled: UUID?
    let date: Date
    let isToday: Bool
    let onAsScheduled: () -> Void
    let onSwitch: (Routine?, Scope) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var asking: Pick?

    var body: some View {
        NavigationStack {
            List {
                Section("Saved workouts") {
                    ForEach(routines) { routine in
                        Button { pick(routine) } label: { row(routine) }
                            .disabled(routine.exercises.isEmpty)
                            .accessibilityIdentifier("today.switch.routine.\(routine.name)")
                    }
                }
                Section {
                    Button(isToday ? "Empty Workout" : "Rest") { pick(nil) }
                        .accessibilityIdentifier("today.switch.empty")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Switch Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .confirmationDialog(title, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                                titleVisibility: .visible, presenting: asking) { pick in
                Button("Only \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))") {
                    finish(pick.routine, .thisDay)
                }
                if pick.routine?.paused != true {
                    Button(pick.routine == nil && isToday ? "Rest every \(weekdayName)" : "Every \(weekdayName)") {
                        finish(pick.routine, .everyWeek)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ routine: Routine) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.name).foregroundStyle(Theme.textPrimary)
                Text(routine.exercises.count == 1 ? "1 exercise" : "\(routine.exercises.count) exercises")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if routine.id == current {
                Image(systemName: "checkmark").foregroundStyle(Theme.primaryFill)
            }
        }
    }

    private var weekdayName: String { WeekPlan.dayName(WeekSchedule.isoWeekday(date)) }

    private var title: String {
        guard let asking else { return "" }
        return "Switch to \(asking.routine?.name ?? (isToday ? "an empty workout" : "rest"))"
    }

    private func pick(_ routine: Routine?) {
        // The day's own workout (on a later rest day, Rest) is the plan as scheduled: nothing to ask.
        if routine?.id == scheduled && (routine != nil || !isToday) {
            dismiss()
            onAsScheduled()
        } else {
            asking = Pick(routine: routine)
        }
    }

    private func finish(_ routine: Routine?, _ scope: Scope) {
        asking = nil
        dismiss()
        onSwitch(routine, scope)
    }
}
