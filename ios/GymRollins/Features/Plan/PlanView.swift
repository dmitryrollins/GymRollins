import GymCore
import GymData
import SwiftUI

/// My Plan is the week (owner, 2026-11-10): Monday to Sunday, each day's workout and first exercises; tapping a day
/// opens its editor (`DayWorkoutEditView`). Saved workouts lists every workout, on the week or not.
struct PlanView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var routines: [Routine] = []
    @State private var schedule = WeekSchedule(days: [:])
    @State private var editingDay: EditingDay?
    @State private var error: String?

    /// The weekday open in the day editor.
    struct EditingDay: Identifiable {
        let weekday: Int
        var id: Int { weekday }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DisplayTitle(text: "My Plan")
                SectionLabel(text: "Your week")
                VStack(spacing: 8) {
                    ForEach(1...7, id: \.self) { weekday in
                        Button { editingDay = EditingDay(weekday: weekday) } label: { dayRow(weekday) }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Change this day's workout")
                            .accessibilityIdentifier("plan.day.\(weekday)")
                    }
                }
                NavigationLink { SavedWorkoutsView() } label: { savedRow }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("plan.savedWorkouts")
                if let error { Text(error).foregroundStyle(Theme.destructive) }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingDay, onDismiss: reload) { DayWorkoutEditView(weekday: $0.weekday) }
        .task(id: env.planRevision) { reload() }
    }

    private func dayRow(_ weekday: Int) -> some View {
        let routine = schedule.days[weekday].flatMap { id in routines.first { $0.id == id && !$0.paused } }
        let names = (routine?.exercises ?? [])
            .map { DisplayName.of(env.library.exercise($0.exerciseId)?.name ?? $0.exerciseId) }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(WeekPlan.dayName(weekday)).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    if weekday == WeekSchedule.isoWeekday(env.now()) { Badge(text: "Today", kind: .record) }
                }
                Text(routine?.name ?? "Rest").font(.headline)
                    .foregroundStyle(routine == nil ? Theme.textSecondary : Theme.textPrimary)
                if !names.isEmpty {
                    Text(WeekPlan.exerciseLine(names)).font(.footnote).foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
    }

    private var savedRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved workouts").font(.headline).foregroundStyle(Theme.textPrimary)
                Text(routines.count == 1 ? "1 workout" : "\(routines.count) workouts")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
        }
        .padding(14)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
    }

    private func reload() {
        do { routines = try env.routines.all(); schedule = try env.routines.schedule(); error = nil }
        catch { self.error = "Couldn't load your plan." }
    }
}
