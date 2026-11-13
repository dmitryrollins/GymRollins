import GymCore
import SwiftUI

/// The exercise screen's bottom bar during a workout: Log All Sets + Log Set (Next exercise / Finish once every set is
/// done), replaced by the rest bar while resting.
struct WorkoutLogBar: View {
    let session: WorkoutSession
    let entryId: UUID
    let sets: [WorkoutSet]
    /// Commits typed values before anything is logged.
    let commit: () -> Void
    let finish: () -> Void
    /// Replaces this screen with another exercise's (the next one to do).
    let open: (UUID) -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // TimelineView only supplies a once-a-second redraw pulse; the actual rest math below uses
        // `env.now()` (the app's own, possibly-fixed-for-tests clock), never the real wall clock.
        // The rest bar takes over this exact floating-bottom-bar slot (via `.safeAreaInset`) rather
        // than being laid out inline, so it never overlaps the set timeline above it.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let now = env.now()
            Group {
                if let rest = session.activeRest(at: now) {
                    RestBar(rest: rest, now: now, onMinus: { session.adjustRest(by: -15) },
                           onPlus: { session.adjustRest(by: 15) }, onSkip: { session.skipRest() })
                } else if dynamicTypeSize.isAccessibilitySize {
                    // Scaled labels don't fit side by side: stack, primary action first.
                    VStack(spacing: 8) {
                        primaryButton
                        logAllButton
                    }
                } else {
                    // "Log All Sets" ~40% / "Log Set" ~60% of the available width, per the mockup.
                    SplitLayout(leadingFraction: 0.4, spacing: 10) {
                        logAllButton
                        primaryButton
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var logAllButton: some View {
        SecondaryGlassButton(title: "Log All Sets", identifier: "logging.logAll", minHeight: 56) {
            commit()
            session.logAllSets(entryId: entryId)
        }
    }

    private var primaryButton: some View {
        if sets.allSatisfy(\.done) {
            let nextId = session.workout.nextEntryToDo(after: entryId)
            return PrimaryGlassButton(title: nextId == nil ? "Finish" : "Next exercise",
                                      identifier: nextId == nil ? "workout.finish" : "logging.next") {
                if let nextId { open(nextId) } else { finish() }
            }
        }
        return PrimaryGlassButton(title: "Log Set", identifier: "logging.logSet", action: logActive)
    }

    /// Logs the next undone set of the entry this screen shows (never the session's advancing
    /// "current" entry), using the committed values of that set.
    private func logActive() {
        commit()
        guard let active = session.entry(entryId)?.sets.first(where: { !$0.done }) else { return }
        session.logNextSet(entryId: entryId, weight: active.weight, reps: active.reps, sec: active.sec)
    }
}
