import GymCore
import SwiftUI

/// The partner's view of a workout link: their own weights, Use for today or Not now, or why it can't open.
struct IncomingWorkoutSheet: View {
    @Environment(AppEnvironment.self) private var env
    @State var screen: IncomingWorkoutScreen
    let close: () -> Void
    let used: () -> Void
    let resume: () -> Void

    var body: some View {
        Group {
            switch screen {
            case let .preview(preview): self.preview(preview)
            case .damaged: message("This link doesn't work. Ask for a new one.", action: closeButton)
            case .tooNew: message("Update GymRollins to open this workout.", action: closeButton)
            case .workoutRunning: message("Finish your current workout first.", action: resumeButton)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private func preview(_ preview: IncomingWorkoutScreen.Preview) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DisplayTitle(text: preview.plan.title, size: 34).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("incoming.title")
                Text(preview.countText).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("incoming.count")
                if let notice = preview.droppedNotice { line(notice, identifier: "incoming.dropped") }
                if preview.replacesToday { line("This replaces today's plan.", identifier: "incoming.replaces") }
                ForEach(preview.rows) { row in
                    ExerciseRow(exercise: env.library.exercise(row.row.exerciseId), fallbackName: row.row.name,
                                subtitle: row.row.subtitle, note: row.note, photoFile: row.row.photoFile)
                        .accessibilityIdentifier("incoming.row.\(row.row.exerciseId)")
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                PrimaryGlassButton(title: "Use for today", identifier: "incoming.use") { use(preview.plan) }
                SecondaryGlassButton(title: "Not now", identifier: "incoming.notNow", action: close)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 8)
        }
    }

    /// A workout that started while the sheet was open (the watch) wins, and the sheet says so.
    private func use(_ plan: TodayPlan) {
        if env.useSharedWorkout(plan) {
            used()
        } else {
            screen = .workoutRunning
        }
    }

    private func message(_ text: String, action: some View) -> some View {
        VStack(spacing: 24) {
            Text(text).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                .accessibilityIdentifier("incoming.message")
            action
        }
        .padding(.horizontal, Theme.gutter)
    }

    private var closeButton: some View {
        SecondaryGlassButton(title: "Close", identifier: "incoming.close", action: close)
    }

    private var resumeButton: some View {
        PrimaryGlassButton(title: "Resume Workout", identifier: "incoming.resume", action: resume)
    }

    private func line(_ text: String, identifier: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.record)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }
}
