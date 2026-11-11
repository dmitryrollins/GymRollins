import GymCore
import GymData
import SwiftUI
import UIKit

struct TodayView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model = TodayModel(routineId: nil, title: "", summary: "", rows: [])
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
    /// The current gym's matcher and photos, read once per reload: set edits rebuild the rows and must not read the store.
    @State private var gymContext: TodayGymContext?
    /// The gym the phone is at, read once per reload (`env.currentGym` reads the store on every call).
    @State private var currentGym: Gym?
    @State private var buildRequested = false
    /// The day shown: today, or a later day edited for that date only (owner, 2026-11-10).
    @State private var day = TodayDay.today
    /// The later day shown was changed by the owner or an agent ("changed for this day", Reset this day).
    @State private var dayChanged = false
    /// Whether the last move went to a later day, for the slide's direction.
    @State private var forward = true
    @State private var showDatePicker = false

    /// Onboarding's "Build me a 4-day upper/lower plan…" prompt: the copyable text offered before "Ask Claude to
    /// build one" pushes the connection screen.
    static let askClaudePrompt = "Build me a training plan using get_profile and propose_plan_changes."

    /// Today reloads when the day moves, the plan changes (My Plan, a sync, an agent's change), the gym or its
    /// equipment changes, or the unit is switched in Settings.
    private struct ReloadKey: Equatable {
        let day: TodayDay
        let plan: Int
        let gym: Int
        let unit: WeightUnit
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    VStack(alignment: .leading, spacing: 14) {
                        dayContent
                    }
                    .id(day.offset)
                    .transition(.push(from: forward ? .trailing : .leading))
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 170)
            }
            .gesture(DaySwipeGesture { show($0 > 0 ? day.next : day.previous) })
            .background(Theme.background)
            .refreshable { await env.sync.syncNow() }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .navigationDestination(isPresented: $showPlan) { PlanView() }
            .navigationDestination(isPresented: $showSettings) { SettingsView() }
            .navigationDestination(isPresented: $showClaudeConnection) { ClaudeConnectionView() }
            .navigationDestination(item: $reviewing) { ProposalReviewView(proposalId: $0) }
            .fullScreenCover(isPresented: $showWorkout, onDismiss: {
                startEntry = nil
                // A finished built workout must not stay on Today with Start; one still running keeps its rows.
                if env.session == nil { reload() }
            }, content: {
                if let session = env.session { WorkoutFlowView(session: session, initialEntry: startEntry) }
            })
            .navigationDestination(item: $openItem) { itemId in
                LoggingView(model: .plan(editor, itemId: itemId), startWorkout: start(from:), canStart: day.isToday)
            }
            .navigationDestination(for: String.self) { ExerciseDetailView(exerciseId: $0) }
            .navigationDestination(item: $detailExercise) { ExerciseDetailView(exerciseId: $0) }
            .navigationDestination(item: $historyExercise) { ExerciseHistoryView(exerciseId: $0) }
            .sheet(isPresented: $showSwitch) { switchSheet }
            .sheet(isPresented: $showDatePicker) { TodayDatePickerSheet(selected: day, now: env.now()) { show($0) } }
            .buildWorkoutFlow(requested: $buildRequested, onStart: startBuilt)
            .sheet(isPresented: $showAddExercise) {
                ExercisePickerView(excluded: plan?.usedExerciseIds ?? []) { ids in
                    guard let plan else { return }
                    apply(plan.adding(ids.compactMap { env.library.exercise($0) }
                        .map { RoutineDefaults.item(for: $0, profile: env.profile) }))
                }
            }
            .sheet(isPresented: Binding(get: { replacingItem != nil }, set: { if !$0 { replacingItem = nil } })) {
                ExercisePickerView(excluded: plan?.usedExerciseIds ?? [], singleSelect: true) { ids in
                    guard let plan, let item = replacingItem, let id = ids.first,
                          let exercise = env.library.exercise(id) else { return }
                    apply(plan.replacing(item, with: RoutineDefaults.item(for: exercise, profile: env.profile)))
                    replacingItem = nil
                }
            }
            .sheet(item: $newRoutine, onDismiss: reload) { RoutineEditView(routine: $0) }
            .sheet(isPresented: $showAskClaude) { askClaudeSheet }
            .exercisePreferenceConfirmation($confirmingNever, error: $loadError)
            .task(id: ReloadKey(day: day, plan: env.planRevision, gym: env.gymRevision, unit: env.profile.unit)) {
                reload()
            }
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
                if running {
                    openItem = nil
                    day = .today
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { reload() }
                // Reopening the app later shows today; Control Center or a sheet doesn't reset it.
                if newPhase == .background { day = .today }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                day = .today
                reload()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                day = .today // a new time zone can move which day is next
                reload()
            }
            .onReceive(NotificationCenter.default.publisher(for: .todayPlanReplaced)) { _ in
                day = .today
                closePushedScreens()
                reload()
            }
            .onReceive(NotificationCenter.default.publisher(for: .resumeWorkoutRequested)) { _ in
                if env.session != nil { showWorkout = true }
            }
        }
    }

    /// The day's content: its title, plan, rows and the editing controls (today's status lines on today only).
    @ViewBuilder
    private var dayContent: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                DisplayTitle(text: day.title(now: env.now()), size: 48)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .accessibilityIdentifier("today.title")
                Text("\(model.title) \u{00B7} \(model.summary)")
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("today.summary")
            }
            Spacer(minLength: 8)
            if env.session == nil && (env.hasAnyRoutine || plan?.kind == .built) { switchButton }
        }
        if day.isToday { todayStatus }
        if let loadError { Text(loadError).foregroundStyle(Theme.destructive) }
        if let session = env.session { resumeBanner(session) }
        if day.isToday && !env.hasAnyRoutine && model.rows.isEmpty { emptyPlanState }
        if let note = model.gymNote { TodayGymNote(text: note) }
        ForEach(model.rows) { row in exerciseRow(row) }
        if env.session == nil {
            addExerciseRow
            if plan?.canSaveToRoutine == true { saveToRoutineButton }
            if !day.isToday && dayChanged { resetDayButton }
            if let plan, !plan.exercises.isEmpty {
                ShareWorkoutButton(identifier: "today.share") { plan.shareSources }
            }
        }
    }

    /// Today only: the gym, the injury-note check-in, an agent's proposal, sync and recovery.
    @ViewBuilder
    private var todayStatus: some View {
        if env.session == nil { GymChipRow(gym: currentGym) }
        LimitsReminder(openPlan: { showPlan = true })
        if let pendingProposal { proposalChip(pendingProposal) }
        SyncStatusBanner()
        RecoveryCard(identifier: "today.recovery")
    }

    /// A later day back to the week: the owner's change and an agent's switch for that date go.
    private var resetDayButton: some View {
        SecondaryGlassButton(title: "Reset this day", identifier: "today.resetDay") {
            guard let plan else { return }
            env.resetLaterDay(plan.day)
            reload()
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let applied = env.lastApplied { undoToast(applied) }
            if env.session != nil {
                PrimaryGlassButton(title: "Resume Workout", identifier: "today.resume") {
                    showWorkout = true
                }
            } else if day.isToday {
                startAndBuild
            } else {
                SecondaryGlassButton(title: "Back to today", identifier: "today.backToToday", minHeight: 56) {
                    show(.today)
                }
            }
        }
        .padding(.horizontal, Theme.gutter).padding(.bottom, 8)
    }

    /// Build workout next to Start; at large text sizes they stack.
    @ViewBuilder
    private var startAndBuild: some View {
        let buildButton = SecondaryGlassButton(title: "Build workout", identifier: "today.build", minHeight: 56) {
            buildRequested = true
        }
        if !model.rows.isEmpty || (plan?.kind == .empty && env.hasAnyRoutine) {
            let startButton = PrimaryGlassButton(title: model.rows.isEmpty ? "Start Empty Workout" : "Start Workout",
                                           identifier: "today.start") { start(from: nil) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buildButton; startButton }
                VStack(spacing: 8) { startButton; buildButton }
            }
        } else {
            buildButton
        }
    }

    /// The Build sheet is gone: today's plan becomes the built workout and it starts like any other. If a workout
    /// started meanwhile (the watch), that one is shown and nothing is built.
    private func startBuilt(_ started: BuiltStart) {
        guard env.session == nil else {
            showWorkout = true
            return
        }
        apply(TodayPlan.built(name: started.name, items: started.items, day: TodayPlan.dayKey(env.now()),
                              listings: started.listings))
        start(from: nil)
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
            Button { showDatePicker = true } label: {
                let date = day.date(now: env.now()).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                // At accessibility sizes the spelled-out date breaks one letter per line; the title names the day.
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "calendar").font(.footnote.weight(.semibold)).accessibilityLabel(date)
                } else {
                    Label(date, systemImage: "calendar").font(.footnote.weight(.semibold))
                }
            }
            .buttonStyle(.glass)
            .disabled(env.session != nil)
            .accessibilityHint("Pick a day to see its workout")
            .accessibilityIdentifier("today.date")
            .accessibilityAction(named: "Next day") { show(day.next) }
            .accessibilityAction(named: "Previous day") { show(day.previous) }
        }
        .padding(.top, 8)
    }

    /// Shows `new` with a slide; a running workout keeps Today on today.
    private func show(_ new: TodayDay) {
        guard env.session == nil, new != day else { return }
        forward = new.offset > day.offset
        withAnimation(.snappy) { day = new }
        reload()
    }

    private var planStore: TodayPlanStore { env.todayPlanStore }

    /// Where the day's changes are kept: today's stored plan, or the later day's (that date only).
    private var dayStore: any TodayPlanSaving {
        day.isToday ? planStore : env.laterDaySaver(on: day.date(now: env.now()), scheduled: scheduledRoutine?.id)
    }

    private var plan: TodayPlan? { editor.plan }

    /// Starts today's workout as planned (with today's edits); from the exercise screen it opens on that exercise.
    private func start(from itemId: UUID?) {
        openItem = nil
        guard env.session == nil else {
            // Started meanwhile (e.g. from the watch): show that workout instead of starting another.
            showWorkout = true
            return
        }
        // A plan for another day (a later day, or yesterday's at midnight) is never started.
        if let plan, plan.day != TodayPlan.dayKey(env.now()) {
            reload()
            return
        }
        let starting = plan
        env.startSession(routine: starting?.routineToStart, setOverrides: starting?.setOverrides ?? [:],
                         restSec: starting?.restSec, loadListings: starting?.builtListings ?? [:])
        planStore.clear()
        editor.isLocked = env.session != nil
        if let itemId, let starting, let workout = env.session?.workout {
            startEntry = starting.entryId(for: itemId, in: workout)
        } else {
            startEntry = nil
        }
        showWorkout = true
    }

    /// A new plan arrived from outside Today (a workout link): whatever was pushed over Today closes, so the plan shows.
    private func closePushedScreens() {
        showPlan = false
        showSettings = false
        showClaudeConnection = false
        reviewing = nil
        openItem = nil
        detailExercise = nil
        historyExercise = nil
    }

    private func reload() {
        // The plan may have changed underneath (My Plan, sync, a new day): the exercise screen shows the new plan
        // (and closes if its exercise is gone).
        historyCache = [:]
        let env = self.env
        editor.isLocked = env.session != nil
        let gym = env.todayGymContext()
        gymContext = gym
        currentGym = env.currentGym
        do {
            let plan: TodayPlan
            if day.isToday {
                let today = try env.todaysPlan()
                plan = today.plan
                scheduledRoutine = today.scheduled
                pendingProposal = env.pendingProposals().first?.id
            } else {
                let later = try env.laterDay(on: day.date(now: env.now()))
                plan = later.plan
                scheduledRoutine = later.scheduled
            }
            editor.configure(store: dayStore, defaultRestSec: env.profile.restSec) { item, plan in
                SessionPlanner.entry(for: item, policy: item.policy ?? plan.base?.policy ?? .double, profile: env.profile,
                                     exercise: env.library.exercise(item.exerciseId),
                                     history: (try? env.workouts.history(exerciseId: item.exerciseId, limit: 5)) ?? [],
                                     autoWarmups: WarmupPreferences.autoWarmupsEnabled(env.defaults),
                                     loads: gym?.preferring(plan.builtListings).loads(for: item.exerciseId)).sets
            }
            editor.load(plan)
            gymContext = gym?.preferring(plan.builtListings)
            refreshModel()
            loadError = nil
        } catch {
            AppEnvironment.log.error("Today load failed: \(error.localizedDescription, privacy: .public)")
            loadError = day.isToday ? "Couldn't load today's plan." : "Couldn't load this day's plan."
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
        let gym = gymContext
        let made = TodayModel.make(plan: plan, profile: env.profile, library: env.library,
                                   history: { cache[$0] ?? [] }, gym: gym, loads: { gym?.loads(for: $0) })
        if day.isToday {
            model = made
        } else {
            dayChanged = env.isLaterDayChanged(plan)
            model = DayPreview.laterDay(made, plan: plan, changed: dayChanged)
        }
    }

    /// Applies a change for the day shown and keeps it for that day.
    private func apply(_ new: TodayPlan) { editor.apply(new) } // the rows follow `editor.plan`

    // MARK: Today's workout controls

    private var switchButton: some View {
        Button { showSwitch = true } label: {
            Label("Switch", systemImage: "arrow.left.arrow.right").font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.glass)
        .accessibilityHint("Pick another workout for this day")
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
                onDelete: { editor.delete(row.id) },
                usePlanned: usePlannedItem(row))
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

    private func usePlannedItem(_ row: TodayModel.Row) -> (name: String, action: () -> Void)? {
        guard case let .swapped(planned, _) = row.gymMark else { return nil }
        return (planned, { editor.usePlanned(row.id) })
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
                if day.isToday { apply(plan.savedToRoutine(at: env.now())) } else { dayStore.clear() }
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

    /// Switch for the day shown. Picking the day's own workout (on a later rest day, Rest) is the plan as scheduled.
    private func choose(_ routine: Routine?) {
        showSwitch = false
        guard let current = plan else { return }
        if routine?.id == scheduledRoutine?.id && (routine != nil || !day.isToday) {
            dayStore.clear()
            reload()
        } else {
            apply(current.switched(to: routine).adapted(by: env.gymAdapter()))
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
            .buttonStyle(.glassProminent).tint(Theme.primaryButtonFill)
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
