import GymCore
import SwiftUI

/// A GymRollins workout, pushed from its Log card, in Apple Fitness' layout (plan 40, spec §4): glass Back, Share (the
/// plain-text recap) and "•••" (Edit / Delete) circles pinned at the top; the header; "Workout Details" with what
/// Apple Health measured, or the estimate; "Effort", rated in a glass sheet; the Heart Rate and Post-Workout Heart Rate
/// charts when Health has readings; "Strength"; and a card per exercise. Edit mode turns each set into its exercise
/// mode's fields and the "Reps left?" chips, as before, with the cards above the sets set aside until Save or Cancel.
/// The app's own values draw at once and Health's fill in when its read finishes, and again when a hook (spec §5.5) or
/// a rating changes them.
struct WorkoutDetailView: View {
    let workoutId: UUID
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var workout: Workout?
    @State private var recordCount = 0
    /// The agent that added this workout (plan 32), read with it; nil for the owner's own.
    @State private var addedBy: String?
    /// What Health measured, else the app's own values (plan 40); nil until the workout is read. Set with `show(_:for:)`.
    @State private var summary: MeasuredSummary?
    /// The two heart-rate charts' data, built from `summary` when it arrives rather than on every body pass.
    @State private var heartRateCharts: WorkoutHeartRateCharts.Model?
    @State private var editing = false
    @State private var drafts: [SetField: String] = [:]
    /// Edited "Reps left?" ratings by set id (a nil value clears the rating), applied on Save.
    @State private var effortDrafts: [UUID: Double?] = [:]
    @State private var showMenu = false
    @State private var showEffort = false
    /// The effort when the sheet opened: it opens on that score and offers Clear Rating by it, so a read landing while
    /// it's open doesn't change it under the owner's finger.
    @State private var effortAtOpen: Effort?
    /// Health is on and allowed but didn't take the last rating (spec §5.4): "Couldn't save to Apple Health".
    @State private var effortNotInHealth = false
    /// Bumped by each rating or clear: only the newest one's answer reaches the screen.
    @State private var effortRound = 0
    /// Ratings or clears still running: `load()` leaves the summary to them.
    @State private var effortPending = 0

    /// What the screen is read from: the workout, the app's data, its measured numbers, and Health on or off.
    private struct LoadKey: Equatable {
        let workoutId: UUID
        let data: Int
        let measured: Int
        let healthOn: Bool
    }

    private var unit: WeightUnit { env.profile.unit }

    private var loadKey: LoadKey {
        LoadKey(workoutId: workoutId, data: env.dataRevision, measured: env.measuredRevision,
                healthOn: env.health.isEnabled)
    }

    var body: some View {
        Group {
            if let workout {
                scrollContent(workout)
            } else {
                Color.clear
            }
        }
        // On the whole screen, so Back is there while the workout loads and if it's gone (deleted by a sync).
        .detailTopBar(topBar)
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showMenu) {
            WorkoutOptionsSheet(onEdit: startEditing, onDelete: delete)
        }
        .sheet(isPresented: $showEffort) {
            EffortSheet(effort: effortAtOpen, canClear: effortAtOpen.map { !$0.estimated } ?? false,
                        onSave: { score in Task { await rateEffort(score) } },
                        onClear: { Task { await clearEffort() } })
        }
        .task(id: loadKey) { await load() }
    }

    // MARK: Top bar

    /// Back always; once the workout is read, Share and "•••", or Cancel and Save while editing. Pinned above the
    /// content.
    private var topBar: DetailTopBar<some View> {
        DetailTopBar(backIdentifier: "detail.back", onBack: { dismiss() }) {
            if let workout {
                if editing {
                    // Capped at accessibility1, as Share is: past it "Cancel" wrapped onto two lines beside Back.
                    Button("Cancel") { cancelEditing() }
                        .buttonStyle(.glass)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .accessibilityIdentifier("detail.cancel")
                    Button("Save", action: save)
                        .prominentGlass()
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .accessibilityIdentifier("detail.save")
                } else {
                    ShareLink(item: shareText(workout)) {
                        // The tallest glyph of the three: past AX1 it outgrew its 44 pt circle.
                        Image(systemName: "square.and.arrow.up").dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    }
                    .glassCircle()
                    .accessibilityLabel("Share")
                    .accessibilityIdentifier("detail.share")
                    Button { showMenu = true } label: { Image(systemName: "ellipsis") }
                        .glassCircle()
                        .accessibilityLabel("Edit or delete workout")
                        .accessibilityIdentifier("detail.menu")
                }
            }
        }
    }

    // MARK: Content

    private func scrollContent(_ workout: Workout) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WorkoutDetailHeader(workout: workout, summary: summary, addedBy: addedBy)
                // While editing, the sets follow the header, under Cancel / Save as before: the cards pushed the
                // first set's fields below the fold, and their numbers only change on Save.
                if !editing {
                    if let summary {
                        WorkoutDetailsCard(summary: summary, estimate: env.calories.estimate(workout),
                                           healthStatus: env.health.exportStatus(for: workout))
                        EffortCard(effort: summary.effort, needsAsking: env.health.effortNeedsAsking,
                                   notInHealth: effortNotInHealth, onOpen: { openEffort(summary.effort) },
                                   onAllow: allowEffort)
                        if let heartRateCharts { WorkoutHeartRateCharts(model: heartRateCharts) }
                    }
                    WorkoutStrengthCard(readings: MeasuredText.strength(workout, records: recordCount))
                }
                WorkoutExerciseList(workout: workout, editing: editing, drafts: $drafts, effortDrafts: $effortDrafts)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
    }

    // MARK: Effort

    private func openEffort(_ effort: Effort?) {
        effortAtOpen = effort
        showEffort = true
    }

    /// The Allow pill: asks for the effort types; a rating Health didn't take before is no longer the question.
    private func allowEffort() {
        effortNotInHealth = false
        Task { await env.allowHealthEffort() }
    }

    /// Kept in the app whatever Health does; the card says so when Health should have taken it and didn't. Started in
    /// its own task, which the screen never cancels, so the Health write always finishes: `effortRound` is what keeps
    /// an older answer off the screen.
    private func rateEffort(_ score: Int) async {
        guard let workout else { return }
        let round = startEffort()
        defer { effortPending -= 1 }
        let saved = await env.rateEffort(score, for: workout)
        let measured = await env.measuredSummary(for: workout)
        // A newer rating or clear started meanwhile: its answer is the one to show.
        guard round == effortRound else { return }
        effortNotInHealth = saved == .savedInAppOnly
        show(measured, for: workout)
    }

    private func clearEffort() async {
        guard let workout else { return }
        let round = startEffort()
        defer { effortPending -= 1 }
        await env.clearEffort(for: workout)
        let measured = await env.measuredSummary(for: workout)
        guard round == effortRound else { return }
        effortNotInHealth = false
        show(measured, for: workout)
    }

    /// A rating or clear begins: counted as running, and its round is the newest.
    private func startEffort() -> Int {
        effortPending += 1
        effortRound += 1
        return effortRound
    }

    // MARK: Share

    /// The plain-text recap the Share circle sends: "Push + Biceps — Sat 19 Sep, 58 min", then a line per exercise.
    private func shareText(_ workout: Workout) -> String {
        let date = workout.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let minutes = Int(durationSeconds(workout) / 60)
        let exercises = workout.entries.compactMap { entry -> String? in
            let sets = WorkoutText.setsSummary(entry, unit: unit,
                                               mode: WorkoutExerciseList.mode(of: entry, library: env.library))
            return sets.isEmpty ? nil : "\(WorkoutExerciseList.name(of: entry, library: env.library)) \(sets)"
        }
        return (["\(workout.name) \u{2014} \(date), \(minutes) min"] + exercises).joined(separator: "\n")
    }

    private func durationSeconds(_ workout: Workout) -> TimeInterval {
        max(0, (workout.endedAt ?? workout.startedAt).timeIntervalSince(workout.startedAt) - workout.pausedSeconds)
    }

    // MARK: Data

    /// The workout, its records and its agent from the store; then the app's own values at once, and Health's when
    /// read.
    private func load() async {
        do {
            workout = try env.workouts.workout(workoutId)
            recordCount = try env.workouts.records(for: workoutId).count
            addedBy = try env.workouts.addedBy(workoutId)
        } catch {
            AppEnvironment.log.error("Load workout failed: \(error.localizedDescription, privacy: .public)")
        }
        guard let workout, workout.endedAt != nil else { return }
        if summary == nil { show(env.immediateMeasuredSummary(for: workout), for: workout) }
        let round = effortRound
        let measured = await env.measuredSummary(for: workout)
        // A newer load (the data, Health or a measured read changed meanwhile) replaced this one, or a rating or clear
        // started meanwhile and shows its own answer: this one writes nothing.
        guard !Task.isCancelled, round == effortRound, effortPending == 0 else { return }
        // Rated or cleared elsewhere (in Fitness, on another device): the last rating's note no longer applies.
        if measured.effort != summary?.effort { effortNotInHealth = false }
        show(measured, for: workout)
    }

    /// The summary, and the charts' data built from it once here rather than on every body pass.
    private func show(_ measured: MeasuredSummary, for workout: Workout) {
        summary = measured
        heartRateCharts = workout.endedAt.flatMap { end in
            WorkoutHeartRateCharts.Model(summary: measured, start: workout.startedAt, end: end)
        }
    }

    private func startEditing() {
        (drafts, effortDrafts) = ([:], [:])
        editing = true
    }

    private func cancelEditing() {
        (drafts, effortDrafts) = ([:], [:])
        editing = false
    }

    private func save() {
        guard var updated = workout else { return }
        for entry in updated.entries {
            let mode = WorkoutExerciseList.mode(of: entry, library: env.library)
            for set in entry.sets {
                if let rir = effortDrafts[set.id] {
                    updated = updated.updatingSet(entryId: entry.id, setId: set.id) { $0.with(rir: rir) }
                }
                for field in SetFieldFormat.fields(for: mode, setId: set.id) {
                    guard let text = drafts[field] else { continue }
                    updated = updated.updatingSet(entryId: entry.id, setId: set.id) { current in
                        SetFieldFormat.applying(text, to: field, set: current, unit: unit) ?? current
                    }
                }
            }
        }
        do {
            try env.workouts.save(updated)
            env.dataChanged()
            workout = updated
            (drafts, effortDrafts) = ([:], [:])
            editing = false
        } catch {
            AppEnvironment.log.error("Save workout failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func delete() {
        do {
            try env.workouts.delete(workoutId)
            env.dataChanged()
            dismiss()
        } catch {
            AppEnvironment.log.error("Delete workout failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
