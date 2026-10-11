import GymCore
import GymData
import SwiftUI
import UIKit

struct TodayView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = TodayModel(routineId: nil, title: "", summary: "", rows: [])
    @State private var currentRoutine: Routine?
    @State private var showPlan = false
    @State private var showWorkout = false
    @State private var loadError: String?
    @State private var pendingProposal: UUID?
    @State private var reviewing: UUID?
    @State private var showSettings = false
    @State private var newRoutine: Routine?
    @State private var showAskClaude = false
    @State private var showClaudeConnection = false
    @State private var copiedPrompt = false
    /// Today's workout before it starts (scheduled, optional rest-day suggestion, switched, or empty), shared with the
    /// plan-mode exercise screen.
    @State private var editor = TodayPlanEditor()
    @State private var scheduledRoutine: Routine?
    @State private var showSwitch = false
    @State private var showAddExercise = false
    @State private var replacingItem: UUID?
    @State private var detailExercise: String?
    @State private var historyExercise: String?
    @State private var confirmingNever: String?
    /// The plan item open in the exercise screen (plan mode).
    @State private var openItem: UUID?
    /// The exercise the workout opens on when it was started from the exercise screen.
    @State private var startEntry: UUID?
    /// Recent sessions per exercise, read once per reload: edits on the exercise screen rebuild the rows and must not
    /// query the workout history each time.
    @State private var historyCache: [String: [SessionResult]] = [:]

    /// Onboarding's "Build me a 4-day upper/lower plan…" prompt: the copyable text offered before "Ask Claude to
    /// build one" pushes the connection screen.
    static let askClaudePrompt = "Build me a training plan using get_profile and propose_plan_changes."

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            DisplayTitle(text: "Today", size: 48)
                            Text("\(model.title) \u{00B7} \(model.summary)")
                                .foregroundStyle(Theme.textSecondary)
                                .accessibilityIdentifier("today.summary")
                        }
                        Spacer(minLength: 8)
                        if env.session == nil && env.hasAnyRoutine { switchButton }
                    }
                    if !env.profile.limits.isEmpty {
                        Text(env.profile.limits).font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(Theme.record)
                            .glassCapsule(tint: Theme.record.opacity(0.25), interactive: false)
                    }
                    if let pendingProposal { proposalChip(pendingProposal) }
                    SyncStatusBanner()
                    RecoveryCard(identifier: "today.recovery")
                    if let loadError { Text(loadError).foregroundStyle(Theme.destructive) }
                    if let session = env.session { resumeBanner(session) }
                    if !env.hasAnyRoutine { emptyPlanState }
                    ForEach(model.rows) { row in exerciseRow(row) }
                    if env.session == nil {
                        addExerciseRow
                        if plan?.canSaveToRoutine == true { saveToRoutineButton }
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 170)
            }
            .background(Theme.background)
            .refreshable { await env.sync.syncNow() }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .navigationDestination(isPresented: $showPlan) { PlanView() }
            .navigationDestination(isPresented: $showSettings) { SettingsView() }
            .navigationDestination(isPresented: $showClaudeConnection) { ClaudeConnectionView() }
            .navigationDestination(item: $reviewing) { ProposalReviewView(proposalId: $0) }
            .fullScreenCover(isPresented: $showWorkout, onDismiss: { startEntry = nil }, content: {
                if let session = env.session { WorkoutFlowView(session: session, initialEntry: startEntry) }
            })
            .navigationDestination(item: $openItem) { itemId in
                LoggingView(model: .plan(editor, itemId: itemId), startWorkout: start(from:))
            }
            .navigationDestination(for: String.self) { ExerciseDetailView(exerciseId: $0) }
            .navigationDestination(item: $detailExercise) { ExerciseDetailView(exerciseId: $0) }
            .navigationDestination(item: $historyExercise) { ExerciseHistoryView(exerciseId: $0) }
            .sheet(isPresented: $showSwitch) { switchSheet }
            .sheet(isPresented: $showAddExercise) {
                ExercisePickerView(excluded: Set(plan?.exercises.map(\.exerciseId) ?? [])) { ids in
                    guard let plan else { return }
                    apply(plan.adding(ids.compactMap { env.library.exercise($0) }
                        .map { RoutineDefaults.item(for: $0, profile: env.profile) }))
                }
            }
            .sheet(isPresented: Binding(get: { replacingItem != nil }, set: { if !$0 { replacingItem = nil } })) {
                ExercisePickerView(excluded: Set(plan?.exercises.map(\.exerciseId) ?? []), singleSelect: true) { ids in
                    guard let plan, let item = replacingItem, let id = ids.first,
                          let exercise = env.library.exercise(id) else { return }
                    apply(plan.replacing(item, with: RoutineDefaults.item(for: exercise, profile: env.profile)))
                    replacingItem = nil
                }
            }
            .sheet(item: $newRoutine, onDismiss: reload) { RoutineEditView(routine: $0) }
            .sheet(isPresented: $showAskClaude) { askClaudeSheet }
            .exercisePreferenceConfirmation($confirmingNever, error: $loadError)
            .task(id: env.planRevision) { reload() }
            // A finished workout changes the history the suggestions come from.
            .onChange(of: env.dataRevision) { _, _ in
                historyCache = [:]
                editor.invalidateSuggestions()
                refreshModel()
            }
            .onChange(of: editor.plan) { _, _ in refreshModel() }
            // A workout started elsewhere (the watch) while the exercise screen was open on today's plan: that plan is
            // spent, so the screen closes and further edits are ignored.
            .onChange(of: env.session != nil) { _, running in
                editor.isLocked = running
                if running { openItem = nil }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { reload() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in reload() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                reload()
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let applied = env.lastApplied { undoToast(applied) }
            if env.session != nil {
                PrimaryGlassButton(title: "Resume Workout", identifier: "today.resume") {
                    showWorkout = true
                }
            } else if !model.rows.isEmpty || (plan?.kind == .empty && env.hasAnyRoutine) {
                PrimaryGlassButton(title: model.rows.isEmpty ? "Start Empty Workout" : "Start Workout",
                                   identifier: "today.start") { start(from: nil) }
            }
        }
        .padding(.horizontal, Theme.gutter).padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { showSettings = true } label: { Text("R").font(.headline) }
                .glassCircle()
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("today.settings")
            Button { showPlan = true } label: { Text("My Plan \u{203A}").font(.subheadline.weight(.semibold)) }
                .buttonStyle(.glass)
                .accessibilityIdentifier("today.myPlan")
            StreakChip()
            Spacer()
            Text(env.now().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(.footnote).foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 8)
    }

    private var planStore: TodayPlanStore { env.todayPlanStore }

    private var plan: TodayPlan? { editor.plan }

    /// Starts today's workout as planned (with today's edits); from the exercise screen it opens on that exercise.
    private func start(from itemId: UUID?) {
        openItem = nil
        guard env.session == nil else {
            // Started meanwhile (e.g. from the watch): show that workout instead of starting another.
            showWorkout = true
            return
        }
        let starting = plan
        env.startSession(routine: starting?.routineToStart, setOverrides: starting?.setOverrides ?? [:],
                         restSec: starting?.restSec)
        planStore.clear()
        editor.isLocked = env.session != nil
        if let itemId, let starting, let workout = env.session?.workout {
            startEntry = starting.entryId(for: itemId, in: workout)
        } else {
            startEntry = nil
        }
        showWorkout = true
    }

    private func reload() {
        // The plan may have changed underneath (My Plan, sync, a new day): the exercise screen shows the new plan
        // (and closes if its exercise is gone).
        historyCache = [:]
        let env = self.env
        editor.isLocked = env.session != nil
        editor.configure(store: planStore, defaultRestSec: env.profile.restSec) { item, plan in
            SessionPlanner.entry(for: item, policy: item.policy ?? plan.base?.policy ?? .double, profile: env.profile,
                                 exercise: env.library.exercise(item.exerciseId),
                                 history: (try? env.workouts.history(exerciseId: item.exerciseId, limit: 5)) ?? [],
                                 autoWarmups: WarmupPreferences.autoWarmupsEnabled(env.defaults)).sets
        }
        do {
            let today = try env.todaysPlan()
            currentRoutine = today.scheduled
            scheduledRoutine = currentRoutine
            editor.load(today.plan)
            refreshModel()
            pendingProposal = env.pendingProposals().first?.id
            loadError = nil
        } catch {
            AppEnvironment.log.error("Today load failed: \(error.localizedDescription, privacy: .public)")
            loadError = "Couldn't load today's plan."
        }
    }

    private func refreshModel() {
        guard let plan else { return }
        let cache = plan.exercises.reduce(into: historyCache) { cache, item in
            if cache[item.exerciseId] == nil {
                cache[item.exerciseId] = (try? env.workouts.history(exerciseId: item.exerciseId, limit: 5)) ?? []
            }
        }
        if cache.count != historyCache.count { historyCache = cache }
        model = TodayModel.make(plan: plan, profile: env.profile, library: env.library,
                                history: { cache[$0] ?? [] })
    }

    /// Applies a today-only change and remembers it for the rest of the day.
    private func apply(_ new: TodayPlan) { editor.apply(new) } // the rows follow `editor.plan`

    // MARK: Today's workout controls

    private var switchButton: some View {
        Button { showSwitch = true } label: {
            Label("Switch", systemImage: "arrow.left.arrow.right").font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.glass)
        .accessibilityHint("Pick another workout for today")
        .accessibilityIdentifier("today.switch")
    }

    /// Before the workout starts a row opens the exercise screen in plan mode; during a workout it's display only.
    private func exerciseRow(_ row: TodayModel.Row) -> some View {
        let editable = env.session == nil
        return TodayExerciseRow(row: row, exercise: env.library.exercise(row.exerciseId),
                                onOpen: editable ? { openItem = row.id } : nil, menu: { rowMenu(row) })
    }

    private func rowMenu(_ row: TodayModel.Row) -> some View {
        Menu {
            TodayExerciseMenuItems(
                exerciseId: row.exerciseId, isEdited: row.setsEdited,
                confirmingNever: $confirmingNever, error: $loadError,
                onDetails: { detailExercise = row.exerciseId }, onHistory: { historyExercise = row.exerciseId },
                onReplace: { replacingItem = row.id }, onReset: { editor.resetSets(row.id) },
                onDelete: { editor.delete(row.id) })
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("More for \(row.name)")
        .accessibilityIdentifier("today.row.menu.\(row.exerciseId)")
    }

    private var addExerciseRow: some View {
        Button { showAddExercise = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .frame(width: 52, height: 52)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.textTertiary, lineWidth: 1))
                Text("Add Exercise").font(.body.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(Theme.primaryFill)
            .padding(10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("today.addExercise")
    }

    private var saveToRoutineButton: some View {
        SecondaryGlassButton(title: "Save Changes to \(plan?.title ?? "Routine")", identifier: "today.saveToRoutine") {
            guard let plan, let routine = plan.routineWithEdits(at: env.now()) else { return }
            do {
                try env.routines.upsert(routine)
                apply(plan.savedToRoutine(at: env.now()))
                env.planChanged()
            } catch GymDataError.invalidInput(let message) {
                loadError = message
            } catch {
                AppEnvironment.log.error("Save to routine failed: \(error.localizedDescription, privacy: .public)")
                loadError = "Couldn't save the routine. Try again."
            }
        }
    }

    private var switchSheet: some View {
        NavigationStack {
            List {
                Section("Routines") {
                    ForEach((try? env.routines.all()) ?? []) { routine in
                        Button {
                            choose(routine)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(routine.name).foregroundStyle(Theme.textPrimary)
                                    Text(routine.exercises.count == 1 ? "1 exercise" : "\(routine.exercises.count) exercises")
                                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                if routine.id == plan?.base?.id {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.primaryFill)
                                }
                            }
                        }
                        .disabled(routine.exercises.isEmpty)
                        .accessibilityIdentifier("today.switch.routine.\(routine.name)")
                    }
                }
                Section {
                    Button("Empty Workout") { choose(nil) }
                        .accessibilityIdentifier("today.switch.empty")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Switch Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSwitch = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Switch for today only. Picking the scheduled routine goes back to the plan as scheduled.
    private func choose(_ routine: Routine?) {
        showSwitch = false
        guard let current = plan else { return }
        if let routine, routine.id == scheduledRoutine?.id {
            planStore.clear()
            editor.load(TodayPlan.make(scheduled: routine, routines: [], lastDone: [:], day: current.day))
            refreshModel()
        } else {
            apply(current.switched(to: routine))
        }
    }

    private func proposalChip(_ id: UUID) -> some View {
        Button { reviewing = id } label: {
            Label("Plan change from Claude", systemImage: "sparkles").font(.footnote.weight(.semibold))
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("today.proposal")
    }

    /// After applying a proposal: "Plan updated · Undo".
    private func undoToast(_ applied: (id: UUID, count: Int)) -> some View {
        HStack(spacing: 10) {
            Text(applied.count == 1 ? "Plan updated \u{00B7} 1 change" : "Plan updated \u{00B7} \(applied.count) changes")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("proposal.toast")
            Spacer()
            Button("Undo") {
                do { try env.undoProposal(applied.id) } catch {
                    AppEnvironment.log.error("Undo failed: \(error.localizedDescription, privacy: .public)")
                    loadError = "Couldn't undo. Your plan wasn't changed."
                }
            }
            .buttonStyle(.glassProminent).tint(Theme.primaryFill)
            .accessibilityIdentifier("proposal.undo")
            Button { env.clearLastApplied() } label: { Image(systemName: "xmark") }
                .buttonStyle(.glass)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("proposal.toastClose")
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    /// First-run: no routine has ever been created (seeded, imported or hand-built).
    private var emptyPlanState: some View {
        VStack(spacing: 12) {
            Text("No plan yet").font(.headline).accessibilityIdentifier("today.empty.title")
            Text("Build a routine to get started, or let Claude plan one for you.")
                .font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            SecondaryGlassButton(title: "Create a Routine", identifier: "today.empty.createRoutine") {
                newRoutine = env.newRoutineDraft()
            }
            SecondaryGlassButton(title: "Ask Claude to Build One", identifier: "today.empty.askClaude") {
                showAskClaude = true
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var askClaudeSheet: some View {
        VStack(spacing: 16) {
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 8)
            FieldLabel(text: "Ask Claude")
            Text(Self.askClaudePrompt).font(.subheadline).textSelection(.enabled)
                .accessibilityIdentifier("today.askClaude.prompt")
            GlassPillButton(title: copiedPrompt ? "Copied" : "Copy Prompt", identifier: "today.askClaude.copy") {
                UIPasteboard.general.string = Self.askClaudePrompt
                copiedPrompt = true
            }
            PrimaryGlassButton(title: "Open Claude Connection", identifier: "today.askClaude.open") {
                showAskClaude = false
                showClaudeConnection = true
            }
            Spacer()
        }
        .padding(20)
        .background(Theme.background)
        .presentationDetents([.medium])
    }

    private func resumeBanner(_ session: WorkoutSession) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("Workout in progress \u{00B7} \(session.workout.name) \u{00B7} " +
                 DurationFormatter.clock(session.elapsed(at: context.date)))
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(Theme.textPrimary)
                .glassCapsule()
                .accessibilityIdentifier("today.resumeBanner")
        }
    }
}
