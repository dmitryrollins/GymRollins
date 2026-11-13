import GymCore
import SwiftUI

/// The exercise screen: hero header, chip row (rest/history/plates/swap), progression hint, set timeline ("Reps left?"
/// under the set just logged), and a floating bottom bar. The same screen serves a running workout (Log All Sets + Log
/// Set, replaced by the rest bar while resting) and the day's plan on Today before it starts ("plan mode": one Start
/// Workout button on today, no clock, `···` is Today's exercise menu). What it shows and edits goes through
/// `ExerciseScreenModel`.
struct LoggingView: View {
    let model: ExerciseScreenModel
    /// Workout mode: finishes the workout (last exercise done).
    var finish: () -> Void = {}
    /// Workout mode: swaps this screen for another exercise's (Next exercise).
    var openEntry: (UUID) -> Void = { _ in }
    /// Plan mode: starts the day's workout (today only, `canStart`) and opens it on this item.
    var startWorkout: (UUID) -> Void = { _ in }
    /// Plan mode: false on a later day (it can be edited, not started).
    var canStart = true
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
    /// The box being typed in, from its first keystroke until it is left (`SetEdit`): its text, which it shows as
    /// typed, and the snapshot of the sets the edit started from. One box is edited at a time; every other box shows
    /// its set's value. Every keystroke is written as it goes; the edit ends when focus leaves the box, on "Done",
    /// before logging, starting or a structural edit, and when the screen goes away.
    @State private var edit: SetEdit?
    /// Bumped when the list starts scrolling or focus moves: closes an open swipe-to-delete button.
    @State private var swipeCloser = 0

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
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting { swipeCloser += 1 }
                    }
                    .onChange(of: focus) { old, new in
                        swipeCloser += 1
                        if let old { commit(old) }
                        if let new { withAnimation { proxy.scrollTo(new.setId, anchor: .center) } }
                    }
                }
                // Under the keyboard too: otherwise the window's black shows behind the bar above the keys.
                .background { Theme.background.ignoresSafeArea() }
                // While a box is being edited the log bar gives way to the keyboard bar: it rides up with
                // the keyboard and would otherwise sit on top of the lower rows, so a tap meant for a box
                // would hit the bar's button instead.
                .safeAreaInset(edge: .bottom) {
                    if focus == nil {
                        bottomBar(sets)
                    } else {
                        KeyboardBar(canMovePrevious: canMoveFocus(-1, sets: sets),
                                    canMoveNext: canMoveFocus(1, sets: sets),
                                    movePrevious: { moveFocus(-1, sets: sets) },
                                    moveNext: { moveFocus(1, sets: sets) },
                                    done: { focus = nil })
                    }
                }
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showRestSettings) { RestSettingsSheet(model: model, exercise: exercise) }
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
        // Typed text means the old unit: never reinterpret it (what it parsed to is already written).
        .onChange(of: env.profile.unit) { _, _ in edit = nil }
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
            let lastLoad = WeightFormatter.format(kg: last.weightKg, lb: last.weightLb, unit: unit, includeSecondary: false)
            let todayLoad = WeightFormatter.format(kg: working.weightKg, lb: working.weightLb, unit: unit,
                                                   includeSecondary: false)
            Text("Last time \(lastCount) \u{00D7} \(lastReps) @ \(lastLoad). Today \(todayLoad) \u{00D7} \(working.reps).")
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
        let isBarbell = exercise?.isBarbellLoaded ?? false
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
                                  onToggleWarmup: model.canToggleWarmup ? { editSets { model.toggleWarmup(set) } } : nil,
                                  swipeCloser: swipeCloser)
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
        .disabled(!model.canAddSet)
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
    /// The workout clock; before the workout (plan mode) there is none, only "Edited" once the day's sets changed.
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
                        onDelete: { editor.delete(itemId) },
                        usePlanned: plannedAnyway(editor, itemId))
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .glassCircle()
            .accessibilityLabel("More options")
            .accessibilityIdentifier("logging.options")
        }
    }

    /// "Use <planned> anyway" for an item the gym swapped.
    private func plannedAnyway(_ editor: TodayPlanEditor, _ itemId: UUID) -> (name: String, action: () -> Void)? {
        guard let planned = editor.plan?.gymSwaps[itemId] else { return nil }
        let name = DisplayName.of(env.library.exercise(planned.exerciseId)?.name ?? planned.exerciseId)
        return (name, { editor.usePlanned(itemId) })
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

// MARK: - Bottom bar, sheets and typing

extension LoggingView {
    // MARK: Bottom bar

    @ViewBuilder
    private func bottomBar(_ sets: [WorkoutSet]) -> some View {
        switch model {
        case .workout(let session, let entryId):
            WorkoutLogBar(session: session, entryId: entryId, sets: sets, commit: commitAll, finish: finish,
                          open: openEntry)
        case .plan where canStart:
            PrimaryGlassButton(title: "Start Workout", identifier: "logging.startWorkout") {
                commitAll()
                startWorkout(model.id)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        case .plan:
            EmptyView()
        }
    }

    /// The edit in progress was on the old exercise's sets: it ends (its typing is already written).
    private func swap(to candidate: Exercise) {
        edit = nil
        let history = (try? env.workouts.history(exerciseId: candidate.id, limit: 5)) ?? []
        model.swap(to: candidate, profile: env.profile, history: history, loads: env.gymLoads(candidate.id))
    }

    private func resetSets(_ editor: TodayPlanEditor, _ itemId: UUID) {
        (edit, focus) = (nil, nil)
        editor.resetSets(itemId)
    }

    // MARK: Typing

    /// Runs a structural edit (add / remove / warm-up) once the edit in progress has ended.
    private func editSets(_ change: () -> Void) { commitAll(); change() }

    /// A box's text: the edit's while it is typed in, else its set's value. Every keystroke is written at once, in one
    /// save (`ExerciseScreenModel.type`): later sets follow live, text that doesn't parse (a cleared box) puts them back
    /// as they were, and in plan mode a workout started meanwhile (from the watch) gets the latest number.
    private func draftBinding(_ field: SetField, set: WorkoutSet) -> Binding<String> {
        Binding(get: {
                    if let edit, edit.field == field { return edit.text }
                    return SetFieldFormat.display(field, set: set, unit: env.profile.unit)
                },
                set: { edit = model.type($0, in: field, continuing: edit, unit: env.profile.unit) })
    }

    /// Every box on the screen in order: each set top to bottom, within a set the mode's field order.
    private func orderedFields(_ sets: [WorkoutSet]) -> [SetField] {
        let mode = SetFieldFormat.mode(exercise: exercise, sets: sets)
        return sets.flatMap { SetFieldFormat.fields(for: mode, setId: $0.id) }
    }

    private func canMoveFocus(_ step: Int, sets: [WorkoutSet]) -> Bool {
        let fields = orderedFields(sets)
        guard let current = focus, let index = fields.firstIndex(of: current) else { return false }
        return fields.indices.contains(index + step)
    }

    /// Previous / next box; the old box is committed by the focus change.
    private func moveFocus(_ step: Int, sets: [WorkoutSet]) {
        guard canMoveFocus(step, sets: sets), let current = focus,
              let index = orderedFields(sets).firstIndex(of: current) else { return }
        focus = orderedFields(sets)[index + step]
    }

    /// Ends the box's edit. Its last text is already written (or, when it didn't parse, the sets are back as they
    /// were), so the box shows its set's value again.
    private func commit(_ field: SetField) {
        if edit?.field == field { edit = nil }
    }

    /// Ends whichever edit is in progress.
    private func commitAll() { edit = nil }
}
