import GymCore
import GymData
import SwiftUI

/// One day of the week (owner, 2026-11-10): which workout it trains (a saved one, a new one, or Rest) and that
/// workout's exercises. When the workout is on other days too and was changed, Done asks whether the change is for all
/// of them or this day only (a copy then takes over the day).
struct DayWorkoutEditView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let weekday: Int
    @State private var routines: [Routine] = []
    /// What the week had on this day when the editor opened (nil: Rest).
    @State private var originalId: UUID?
    /// The workout the day trains in this editor (nil: Rest), and whether it is new.
    @State private var picked: Routine?
    @State private var isNew = false
    @State private var name = ""
    @State private var items: [RoutineExercise] = []
    @State private var showPicker = false
    /// The other days the changed workout is on, while Done's question is open.
    @State private var sharedDays: [Int] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Menu { pickerItems } label: {
                        HStack {
                            Text("Workout").foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(picked == nil ? "Rest" : name.isEmpty ? "Workout" : name)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .accessibilityIdentifier("day.workout")
                    if picked != nil {
                        TextField("Workout name", text: $name).accessibilityIdentifier("edit.name")
                            .onChange(of: name) { _, new in
                                if new.count > DomainLimits.routineNameMax {
                                    name = String(new.prefix(DomainLimits.routineNameMax))
                                }
                            }
                    }
                }
                if picked != nil { RoutineExercisesSection(items: $items, showPicker: $showPicker) }
                if let error {
                    Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("edit.error")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .environment(\.editMode, .constant(.active))
            .navigationTitle(WeekPlan.dayName(weekday))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done).buttonStyle(.glassProminent).tint(Theme.primaryButtonFill)
                        .accessibilityIdentifier("edit.done")
                }
            }
            .sheet(isPresented: $showPicker) {
                ExercisePickerView(excluded: Set(items.map(\.exerciseId))) { ids in
                    items += ids.compactMap { env.library.exercise($0) }
                        .map { RoutineDefaults.item(for: $0, profile: env.profile) }
                }
            }
            .confirmationDialog("\(name) is also on \(WeekPlan.dayList(sharedDays))",
                                isPresented: Binding(get: { !sharedDays.isEmpty }, set: { if !$0 { sharedDays = [] } }),
                                titleVisibility: .visible) {
                Button("Change \(WeekPlan.dayList([weekday] + sharedDays))") { save(onlyThisDay: false) }
                Button("Only \(WeekPlan.dayName(weekday))") { save(onlyThisDay: true) }
                Button("Cancel", role: .cancel) {}
            }
            .task { if !loaded { load() } }
        }
    }

    @ViewBuilder
    private var pickerItems: some View {
        Button("Rest") { pick(nil, isNew: false) }
        ForEach(routines.filter { !$0.paused }) { routine in
            Button(routine.name) { pick(routine, isNew: false) }
        }
        Button("New workout") {
            let draft = env.newRoutineDraft()
            pick(Routine(id: draft.id, name: "\(WeekPlan.dayName(weekday)) workout", policy: draft.policy), isNew: true)
        }
    }

    private func pick(_ routine: Routine?, isNew: Bool) {
        picked = routine
        self.isNew = isNew
        name = routine?.name ?? ""
        items = routine?.exercises ?? []
        error = nil
    }

    private func load() {
        do {
            routines = try env.routines.all()
            let id = try env.routines.schedule().days[weekday]
            let scheduled = routines.first { $0.id == id && !$0.paused }
            originalId = scheduled?.id
            pick(scheduled, isNew: false)
            loaded = true
        } catch {
            AppEnvironment.log.error("Day editor load failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't load this day."
        }
    }

    /// The picked workout with this editor's name and exercises.
    private var edited: Routine? {
        picked.map { Routine(id: $0.id, name: name.trimmingCharacters(in: .whitespaces), emoji: $0.emoji,
                             policy: $0.policy, paused: false, exercises: items) }
    }

    private var changed: Bool {
        guard let picked, let edited else { return false }
        return isNew || edited.name != picked.name || edited.exercises != picked.exercises
    }

    private func done() {
        guard let edited else { return assign(nil) }
        if let violation = DomainLimits.routineViolation(edited) { error = violation; return }
        let others: [Int]
        do {
            others = isNew ? [] : try env.otherDays(of: edited.id, besides: weekday)
        } catch {
            AppEnvironment.log.error("Day editor other days failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't check this workout's other days. Try again."
            return
        }
        if changed && !others.isEmpty { sharedDays = others } else { save(onlyThisDay: false) }
    }

    /// Writes the day: the workout (for all its days, or as this day's own copy) and the week.
    private func save(onlyThisDay: Bool) {
        sharedDays = []
        guard let edited else { return }
        do {
            if onlyThisDay {
                try env.saveWorkout(edited, onlyOn: weekday)
            } else {
                if changed { try env.saveWorkout(edited) }
                if edited.id != originalId { try env.schedule(every: weekday, edited.id) }
            }
            dismiss()
        } catch GymDataError.invalidInput(let message) {
            error = message
        } catch {
            AppEnvironment.log.error("Save day failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save this day. Try again."
        }
    }

    private func assign(_ id: UUID?) {
        guard id != originalId else { return dismiss() }
        do {
            try env.schedule(every: weekday, id)
            dismiss()
        } catch {
            AppEnvironment.log.error("Save day failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save this day. Try again."
        }
    }
}
