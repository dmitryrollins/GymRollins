import GymCore
import GymData
import SwiftUI

struct PlanView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var routines: [Routine] = []
    @State private var schedule = WeekSchedule(days: [:])
    @State private var editing: Routine?
    @State private var error: String?
    private let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DisplayTitle(text: "My Plan")
                SectionLabel(text: "This week")
                week
                SectionLabel(text: "Routines")
                ForEach(routines) { routine in
                    Button { editing = routine } label: { routineRow(routine) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("plan.routine.\(routine.name)")
                }
                GlassPillButton(title: "+ Routine", identifier: "plan.addRoutine") {
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

    private var week: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { day in
                Menu {
                    Button("Rest") { assign(day, nil) }
                    ForEach(routines.filter { !$0.paused }) { r in Button(r.name) { assign(day, r.id) } }
                } label: {
                    VStack(spacing: 4) {
                        Text(dayNames[day - 1]).font(.caption2).foregroundStyle(Theme.textTertiary)
                        Text(shortName(schedule.days[day])).font(.caption.weight(.semibold))
                            .foregroundStyle(schedule.days[day] == nil ? Theme.textTertiary : Theme.textPrimary)
                            .lineLimit(2).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Theme.card, in: .rect(cornerRadius: 12))
                }
                .accessibilityIdentifier("plan.day.\(day)")
            }
        }
    }

    private func routineRow(_ r: Routine) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.headline).foregroundStyle(Theme.textPrimary)
                Text("\(r.exercises.count) exercises").font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if r.paused { Badge(text: "Paused", kind: .record) }
            Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary)
        }
        .padding(14)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        .opacity(r.paused ? 0.7 : 1)
    }

    private func shortName(_ id: UUID?) -> String {
        guard let id, let r = routines.first(where: { $0.id == id }) else { return "Rest" }
        return r.name.components(separatedBy: " + ").first ?? r.name
    }

    private func assign(_ day: Int, _ routineId: UUID?) {
        do { try env.routines.setSchedule(weekday: day, routineId: routineId); env.planChanged() }
        catch { self.error = "Couldn't update the schedule." }
    }

    private func reload() {
        do { routines = try env.routines.all(); schedule = try env.routines.schedule(); error = nil }
        catch { self.error = "Couldn't load your plan." }
    }
}
