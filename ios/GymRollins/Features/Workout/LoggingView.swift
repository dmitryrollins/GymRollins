import GymCore
import SwiftUI

/// The exercise screen: hero header, chip row (rest/history/plates/swap), progression hint, set timeline ("Reps left?"
/// under the set just logged), and a floating bottom bar. The same screen serves a running workout (Log All Sets + Log
/// Set, replaced by the rest bar while resting) and Today's plan before it starts ("plan mode": one Start Workout
/// button, no clock, `···` is Today's exercise menu). What it shows and edits goes through `ExerciseScreenModel`.
struct LoggingView: View {
    let model: ExerciseScreenModel
    /// Workout mode: finishes the workout (last exercise done).
    var finish: () -> Void = {}
    /// Plan mode: starts today's workout and opens it on this item.
    var startWorkout: (UUID) -> Void = { _ in }
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var showOptions = false
    @State private var showRestSettings = false
    @State private var showHistory = false
    @State private var showPlates = false
    @State private var showSwap = false
    @State private var detailExercise: String?
    @State private var confirmingNever: String?
    @State private var menuError: String?
    @State private var history: [SessionResult] = []
    /// The one focus state for every box on the screen (see `SetTimelineRow`).
    @FocusState private var focus: SetField?
    /// Text the user has typed but not yet committed, keyed by box. A box without a draft shows
    /// the current value; drafts are committed when focus leaves the box, on "Done", before
    /// logging or starting, and when the screen goes away -- never per keystroke.
    @State private var drafts: [SetField: String] = [:]

    private var exercise: Exercise? { model.exerciseId.flatMap { env.library.exercise($0) } }

    var body: some View {
        Group {
            if let sets = model.sets, let exerciseId = model.exerciseId {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            hero(exerciseId)
                            VStack(alignment: .leading, spacing: 12) {
                                if let menuError {
                                    Text(menuError).font(.footnote).foregroundStyle(Theme.destructive)
                                }
                                chipRow
                                progressionHint(sets)
                                setsSection(sets)
                            }
                            .padding(.top, 14)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 120)
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: focus) { old, new in
                        if let old { commit(old) }
                        if let new { withAnimation { proxy.scrollTo(new.setId, anchor: .center) } }
                    }
                }
                .background(Theme.background)
                // Hidden while a box is being edited: the bar rides up with the keyboard and
                // would otherwise sit on top of the lower rows, so a tap meant for a box would
                // hit the bar's button instead.
                .safeAreaInset(edge: .bottom) {
                    if focus == nil { bottomBar(sets) }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        // iOS 26's confirm role draws the system's round, tinted checkmark above the keyboard.
                        Button("Done", systemImage: "checkmark", role: .confirm) { focus = nil }
                            .tint(Theme.primaryFill)
                            .accessibilityIdentifier("keyboard.done")
                    }
                }
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showRestSettings) { RestSettingsSheet(model: model) }
        .sheet(isPresented: $showHistory) {
            // `ExerciseHistoryView` doesn't wrap its own `NavigationStack` (nesting one inside
            // Body's existing stack broke that push entry point), so the sheet provides it here.
            if let exerciseId = model.exerciseId { NavigationStack { ExerciseHistoryView(exerciseId: exerciseId) } }
        }
        .sheet(isPresented: $showPlates) {
            if let sets = model.sets { PlatesSheet(weightKg: plateTargetWeightKg(sets)) }
        }
        .sheet(isPresented: $showSwap) {
            if let exerciseId = model.exerciseId {
                SwapSheet(exerciseId: exerciseId, excluded: model.swapExcluded, onPick: swap)
            }
        }
        .sheet(isPresented: $showOptions) {
            if case .workout(let session, let entryId) = model {
                ExerciseOptionsSheet(session: session, entryId: entryId)
            }
        }
        .navigationDestination(item: $detailExercise) { ExerciseDetailView(exerciseId: $0) }
        .exercisePreferenceConfirmation($confirmingNever, error: $menuError)
        .onDisappear(perform: commitAll)
        // Typed text means the old unit: never reinterpret it (valid plan typing is already applied).
        .onChange(of: env.profile.unit) { _, _ in drafts = [:] }
        .task(id: model.id) {
            if case .workout(let session, let entryId) = model { session.select(entryId) }
        }
        // Keyed by the exercise, not the entry: a swap keeps the entry id but changes the exercise.
        .task(id: model.exerciseId) {
            history = model.exerciseId.flatMap { try? env.workouts.history(exerciseId: $0, limit: 1) } ?? []
        }
    }

    // MARK: Hero

    private func hero(_ exerciseId: String) -> some View {
        ZStack {
            Theme.cardInner
            // The AI badge sits on the right under the options button, clear of the clock and the title.
            ExercisePhotoView(exercise: exercise, iconSize: 120, aiBadgeAlignment: .topTrailing,
                              aiBadgePadding: EdgeInsets(top: 104, leading: 0, bottom: 0, trailing: 20))
            // Decorative: taps fall through to the photo's tap-to-flip.
            LinearGradient(colors: [.clear, Theme.background.opacity(0.9)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack {
                HStack(alignment: .top, spacing: 8) {
                    closeButton
                    heroStatus
                    Spacer()
                    optionsButton
                }
                Spacer()
                HStack(alignment: .bottom) {
                    Text(DisplayName.of(exercise?.name ?? exerciseId))
                        .font(Theme.display(34))
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .padding(.trailing, 4) // room for the italic face's overhang (audit: text clipped)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityIdentifier("logging.title")
                    Spacer(minLength: 8)
                    howToButton(exerciseId)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 54)
            .padding(.bottom, 22)
        }
        .frame(minHeight: 260)
        .clipped()
        .ignoresSafeArea(edges: .top)
    }

    // MARK: Chips + hint

    /// One line that scrolls sideways, edge to edge (it reaches past the screen's side padding so a cut-off chip
    /// shows there's more), to keep the set list high on the screen.
    private var chipRow: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    chip(title: "\(DurationFormatter.clock(model.restSeconds)) rest", icon: "timer",
                        identifier: "logging.chip.rest") { showRestSettings = true }
                    chip(title: "History", icon: "chart.bar", identifier: "logging.chip.history") { showHistory = true }
                    chip(title: "Plate Calculator", icon: "square.grid.3x3", identifier: "logging.chip.plates") {
                        showPlates = true
                    }
                    chip(title: "Swap", icon: "arrow.left.arrow.right", identifier: "logging.chip.swap") {
                        showSwap = true
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, Self.sidePadding, for: .scrollContent)
        .padding(.horizontal, -Self.sidePadding)
    }

    /// The screen content's side padding, which the chip row scrolls under.
    private static let sidePadding: CGFloat = 20

    private func chip(title: String, icon: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.footnote.weight(.semibold)) }
            .buttonStyle(HitAreaButtonStyle())
            .glassCapsule()
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func progressionHint(_ sets: [WorkoutSet]) -> some View {
        if let last = history.first, let working = sets.first(where: { !$0.warmup }) {
            let unit = env.profile.unit
            let lastCount = max(last.reps.count, 1)
            let lastReps = last.reps.first ?? 0
            Text("Last time \(lastCount) \u{00D7} \(lastReps) @ " +
                 "\(WeightFormatter.format(kg: last.weightKg, unit: unit, includeSecondary: false)). Today " +
                 "\(WeightFormatter.format(kg: working.weightKg, unit: unit, includeSecondary: false)) \u{00D7} \(working.reps).")
                .font(.caption)
                .foregroundStyle(Theme.success.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.card, in: .rect(cornerRadius: 14))
                .accessibilityIdentifier("logging.hint")
        }
    }

    // MARK: Set timeline

    private func setsSection(_ sets: [WorkoutSet]) -> some View {
        let unit = env.profile.unit
        let isBarbell = SessionPlanner.barbellEquipment.contains(exercise?.equipment ?? "")
        let mode = SetFieldFormat.mode(exercise: exercise, sets: sets)
        let activeId = activeSet(sets)?.id
        let ordinals = SetOrdinal.ordinals(for: sets)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 2)
                .padding(.leading, 13)
                .padding(.vertical, 13)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(sets.enumerated()), id: \.element.id) { offset, set in
                    let remove: (() -> Void)? = model.canRemoveSet(set) ? { editSets { model.removeSet(set) } } : nil
                    SetTimelineRow(set: set, index: offset, ordinal: ordinals[offset], isActive: set.id == activeId,
                                  mode: mode, unit: unit, isBarbell: isBarbell,
                                  text: { draftBinding($0, set: set) }, focus: $focus, isPlanned: model.isPlan,
                                  onRemove: remove,
                                  onToggleWarmup: model.canToggleWarmup ? { editSets { model.toggleWarmup(set) } } : nil)
                        .swipeToDelete(identifier: "logging.set.\(offset).delete", onDelete: remove)
                        .id(set.id)
                    if set.id == model.effortPromptSetId(mode: mode) { // optional rating of the set just logged; the rest keeps running
                        SetEffortRow(rir: set.rir) { model.rateSet(set, tapping: $0) }.padding(.leading, 40)
                    }
                }
                addSetButton
            }
        }
    }

    private var addSetButton: some View {
        Button {
            editSets { model.addSet() }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    HexagonShape().fill(Theme.accent.opacity(0.35))
                    Image(systemName: "plus").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                }
                .frame(width: 28, height: 26)
                Text("Add Set").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .accessibilityIdentifier("logging.addSet")
    }

    private func activeSet(_ sets: [WorkoutSet]) -> WorkoutSet? { sets.first { !$0.done } }

    /// Plate math is most useful for the working weight, not whatever warm-up happens to be next.
    private func plateTargetWeightKg(_ sets: [WorkoutSet]) -> Double {
        let working = sets.first { !$0.warmup && !$0.done }
        return working?.weightKg ?? activeSet(sets)?.weightKg ?? sets.first?.weightKg ?? 0
    }
}

// MARK: - Hero controls

extension LoggingView {
    /// The workout clock; before the workout (plan mode) there is none, only "Edited" once today's sets changed.
    @ViewBuilder
    private var heroStatus: some View {
        switch model {
        case .workout(let session, _): clockCapsule(session)
        case .plan:
            if model.isEdited {
                Label("Edited", systemImage: "pencil")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .glassCapsule(interactive: false)
                    .accessibilityIdentifier("logging.edited")
            }
        }
    }

    private func clockCapsule(_ session: WorkoutSession) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 6) {
                Image(systemName: "timer").font(.caption.weight(.semibold)).accessibilityHidden(true)
                Text(DurationFormatter.clock(session.elapsed(at: env.now()))).font(Theme.display(15))
            }
            .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .glassCapsule()
        .accessibilityIdentifier("logging.clock")
    }

    @ViewBuilder
    private var optionsButton: some View {
        switch model {
        case .workout:
            Button { showOptions = true } label: { Image(systemName: "ellipsis") }
                .glassCircle()
                .accessibilityLabel("More options")
                .accessibilityIdentifier("logging.options")
        case .plan(let editor, let itemId):
            Menu {
                if let exerciseId = model.exerciseId {
                    TodayExerciseMenuItems(
                        exerciseId: exerciseId, isEdited: model.isEdited,
                        confirmingNever: $confirmingNever, error: $menuError,
                        onDetails: { detailExercise = exerciseId }, onHistory: { showHistory = true },
                        onReplace: { showSwap = true }, onReset: { resetSets(editor, itemId) },
                        onDelete: { editor.delete(itemId) })
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .glassCircle()
            .accessibilityLabel("More options")
            .accessibilityIdentifier("logging.options")
        }
    }

    /// Back arrow on the left, where iOS puts Back (the screen is pushed, not presented).
    private var closeButton: some View {
        Button { dismiss() } label: { Image(systemName: "chevron.left") }
            .glassCircle()
            .accessibilityLabel("Back")
            .accessibilityIdentifier("logging.close")
    }

    /// Opens the details through this screen's own destination: a value link would be pushed onto the stack under
    /// a screen that Today opened by state (plan mode), showing this screen again with How-To behind it.
    private func howToButton(_ exerciseId: String) -> some View {
        Button { detailExercise = exerciseId } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.caption2).accessibilityHidden(true)
                Text("How-To")
            }
            .font(.footnote.weight(.bold))
        }
        .buttonStyle(HitAreaButtonStyle())
        .glassCapsule()
        .accessibilityIdentifier("logging.howto")
    }
}

// MARK: - Bottom bar, sheets and drafts

extension LoggingView {
    // MARK: Bottom bar

    @ViewBuilder
    private func bottomBar(_ sets: [WorkoutSet]) -> some View {
        switch model {
        case .workout(let session, let entryId):
            WorkoutLogBar(session: session, entryId: entryId, sets: sets, commit: commitAll, finish: finish,
                          next: { dismiss() })
        case .plan:
            PrimaryGlassButton(title: "Start Workout", identifier: "logging.startWorkout") {
                commitAll()
                startWorkout(model.id)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    /// Typed values were for the old exercise's sets: they go with it.
    private func swap(to candidate: Exercise) {
        drafts = [:]
        let history = (try? env.workouts.history(exerciseId: candidate.id, limit: 5)) ?? []
        model.swap(to: candidate, profile: env.profile, history: history)
    }

    private func resetSets(_ editor: TodayPlanEditor, _ itemId: UUID) {
        (drafts, focus) = ([:], nil)
        editor.resetSets(itemId)
    }

    // MARK: Drafts

    /// Runs a structural edit (add / remove / warm-up) with pending typing applied first.
    private func editSets(_ edit: () -> Void) { commitAll(); edit() }

    /// In plan mode every keystroke that parses also goes into today's plan at once (the text stays as typed until
    /// the box is left), so a workout started meanwhile (from the watch) gets the latest number.
    private func draftBinding(_ field: SetField, set: WorkoutSet) -> Binding<String> {
        Binding(get: { drafts[field] ?? SetFieldFormat.display(field, set: set, unit: env.profile.unit) },
                set: { typed in
                    drafts[field] = typed
                    guard model.isPlan else { return }
                    let unit = env.profile.unit
                    model.updateSetCarryingWeight(field.setId) { SetFieldFormat.applying(typed, to: field, set: $0, unit: unit) ?? $0 }
                })
    }

    /// Applies one box's draft (invalid text is dropped, reverting the box).
    private func commit(_ field: SetField) {
        guard let text = drafts.removeValue(forKey: field) else { return }
        let unit = env.profile.unit
        model.updateSetCarryingWeight(field.setId) { SetFieldFormat.applying(text, to: field, set: $0, unit: unit) ?? $0 }
    }

    private func commitAll() {
        drafts.keys.forEach(commit)
    }
}
