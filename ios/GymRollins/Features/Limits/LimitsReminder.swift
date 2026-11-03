import GymCore
import GymData
import SwiftUI

/// Today's injury note: the reminder before its end date, and the check-in card on or after it.
struct LimitsReminder: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    let openPlan: () -> Void
    @State private var model = LimitsCheckInModel()
    /// When the date was last checked: refreshed at midnight and when the app comes back, so the card appears on its
    /// day without a reload.
    @State private var checkedAt: Date?

    private var due: Bool {
        LimitsCheckIn.isDue(note: env.profile.limits, until: env.profile.limitsUntil, now: checkedAt ?? env.now(),
                            calendar: .current)
    }

    var body: some View {
        Group {
            if model.showsCard(due: due, workoutRunning: env.session != nil) {
                LimitsCheckInCard(model: $model, note: env.profile.limits, until: env.profile.limitsUntil,
                                  dates: LimitsCheckIn.allowedDates(now: env.now(), calendar: .current),
                                  yes: yes, notYet: { model.askLater(now: env.now()) }, saveDate: saveDate,
                                  resume: resume, openPlan: { model.close(); openPlan() })
            } else if !env.profile.limits.isEmpty {
                Text(LimitsCheckInModel.reminder(note: env.profile.limits, until: env.profile.limitsUntil))
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .foregroundStyle(Theme.record)
                    .glassCapsule(tint: Theme.record.opacity(0.25), interactive: false)
                    .accessibilityIdentifier("today.limits")
            }
        }
        // A new date that's already due (set elsewhere, or synced in) asks again from the start.
        .onChange(of: due) { _, isDue in if isDue { model = LimitsCheckInModel() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in checkedAt = env.now() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { checkedAt = env.now() } }
    }

    private func yes() {
        do {
            let paused = try env.pausedRoutines().map { LimitsCheckInModel.PausedRoutine(id: $0.id, name: $0.name) }
            try env.clearLimits()
            model.cleared(paused: paused)
        } catch {
            AppEnvironment.log.error("Clear limits failed: \(error.localizedDescription, privacy: .public)")
            model.failed(LimitsCheckInModel.saveFailed)
        }
    }

    private func saveDate() {
        do {
            try env.postponeLimits(to: GoalDate.normalized(model.nextDate))
            model = LimitsCheckInModel()
        } catch {
            AppEnvironment.log.error("Postpone limits failed: \(error.localizedDescription, privacy: .public)")
            model.failed(LimitsCheckInModel.saveFailed)
        }
    }

    private func resume(_ routine: LimitsCheckInModel.PausedRoutine) {
        do {
            if let result = try env.resumeAtReturnWeights(routine.id) {
                model.resumed(routine.id, name: result.name, lowered: result.lowered)
            } else {
                model.dropped(routine.id)
            }
        } catch {
            AppEnvironment.log.error("Resume routine failed: \(error.localizedDescription, privacy: .public)")
            model.failed(LimitsCheckInModel.resumeFailed(routine.name))
        }
    }
}
