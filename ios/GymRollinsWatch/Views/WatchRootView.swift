import GymWatchLink
import SwiftUI

/// Idle (start today's workout) or the running phone workout.
struct WatchRootView: View {
    @Environment(WatchAppModel.self) private var app

    var body: some View {
        NavigationStack {
            if let workout = app.workout.workout {
                WorkoutPagesView(workout: workout)
            } else {
                IdleView()
            }
        }
        .task { await app.recorder.prepare() }
    }
}

/// No workout on the phone: offer today's plan.
struct IdleView: View {
    @Environment(WatchAppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("GymRollins").font(.headline).foregroundStyle(WatchTheme.accent)
                if let today = app.workout.state?.today {
                    Text(today.title).font(.title3.weight(.semibold))
                    Button("Start today's workout") { app.workout.startToday() }
                        .buttonStyle(.borderedProminent)
                        .tint(WatchTheme.accent)
                        .disabled(!today.canStart)
                } else {
                    Text("Start a workout on your iPhone.").foregroundStyle(.secondary)
                    Button("Start today's workout") { app.workout.startToday() }
                }
                if let notice = app.workout.notice {
                    Text(notice).font(.footnote).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Today")
    }
}

enum WatchTheme {
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.21)
}
