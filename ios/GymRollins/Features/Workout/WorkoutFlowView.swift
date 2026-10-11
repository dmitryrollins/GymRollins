import GymCore
import SwiftUI

/// Full-screen container for an in-progress workout: the exercise overview, pushed logging
/// screens per exercise, the finish confirmation, and the post-workout summary.
struct WorkoutFlowView: View {
    @Bindable var session: WorkoutSession
    @State private var path: NavigationPath
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var showFinishSheet = false
    @State private var summary: (summary: WorkoutSummary, workout: Workout)?
    @State private var finishFailed = false
    /// `IdleFinish`'s earlier end, worked out when Finish is tapped (nil: the last set was recent, or none).
    @State private var suggestedEnd: Date?
    /// Every set done and the last one long ago: asks when the workout ends before finishing.
    @State private var showIdlePrompt = false
    /// The end chosen for the direct finish, kept for "Try again".
    @State private var directEnd: Date?
    @AppStorage(RestPreferences.soundKey) private var restSound = true

    /// `initialEntry` opens the flow straight on that exercise's screen (started from Today's exercise screen); Back
    /// leads to the overview as usual.
    init(session: WorkoutSession, initialEntry: UUID? = nil) {
        self.session = session
        _path = State(initialValue: NavigationPath(initialEntry.map { [$0] } ?? []))
    }

    var body: some View {
        content
        #if DEBUG
            .overlay(alignment: .top) {
                VStack(spacing: 2) {
                    if LiveActivityProbe.isEnabled { LiveActivityProbe() }
                    if FakeWatchTransport.isEnabled { FakeWatchProbe() }
                }
            }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let summary {
                SummaryView(summary: summary.summary, workout: summary.workout) {
                    env.endSession()
                    dismiss()
                }
            } else {
                NavigationStack(path: $path) {
                    WorkoutOverviewView(session: session, finish: finish)
                        .navigationDestination(for: UUID.self) { entryId in
                            LoggingView(model: .workout(session, entryId: entryId), finish: finish)
                        }
                        .navigationDestination(for: String.self) { exerciseId in
                            ExerciseDetailView(exerciseId: exerciseId)
                        }
                }
                // Once for the whole flow (overview and logging both show the rest timer).
                .sensoryFeedback(trigger: session.restCompletions) { _, _ in
                    RestFeedback.onRestCompleted(soundEnabled: restSound)
                }
                .onChange(of: session.restCompletions) {
                    AccessibilityNotification.Announcement(RestAccessibilityText.restOver).post()
                }
                .sheet(isPresented: $showFinishSheet) {
                    FinishSheet(session: session, suggestedEnd: suggestedEnd, onFinished: finished,
                                onDiscarded: discarded)
                }
                .sheet(isPresented: $showIdlePrompt) { idlePrompt }
                .alert("Couldn't finish the workout", isPresented: $finishFailed) {
                    Button("Try again") { finishDirectly(endingAt: directEnd) }
                    Button("Keep going", role: .cancel) {}
                } message: {
                    Text("Your sets are still saved. Try again, or keep going and finish later.")
                }
            }
        }
    }

    /// The direct finish's "end at the last set or now?" question (`FinishSheet` asks it itself).
    @ViewBuilder
    private var idlePrompt: some View {
        if let suggestedEnd {
            IdleFinishPrompt(idleSeconds: session.lastSetAt.map { env.now().timeIntervalSince($0) } ?? 0,
                             suggestedEnd: suggestedEnd,
                             onChoose: { choice in
                                 showIdlePrompt = false
                                 finishDirectly(endingAt: choice.date)
                             },
                             onKeepGoing: { showIdlePrompt = false })
                .padding(22)
                .presentationDetents([.medium])
        }
    }

    /// Presents `FinishSheet` when sets are still undone; otherwise finishes straight away, first asking when the
    /// workout ended if the last set was long ago.
    private func finish() {
        suggestedEnd = session.idleFinishSuggestion()
        if session.workout.undoneSetCount > 0 {
            showFinishSheet = true
        } else if suggestedEnd != nil {
            showIdlePrompt = true
        } else {
            finishDirectly(endingAt: nil)
        }
    }

    /// All sets are done: finish straight away at `end` (nil: now), surfacing any failure with a retry.
    private func finishDirectly(endingAt end: Date?) {
        directEnd = end
        do {
            let result = try session.finish(discardingUndone: false, endingAt: end)
            summary = (result, session.workout)
            env.dataChanged()
        } catch {
            finishFailed = true
        }
    }

    private func finished(_ result: WorkoutSummary) {
        summary = (result, session.workout)
        showFinishSheet = false
        env.dataChanged()
    }

    private func discarded() {
        env.endSession()
        dismiss()
    }
}
