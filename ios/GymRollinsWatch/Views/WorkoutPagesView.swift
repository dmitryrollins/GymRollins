import GymWatchLink
import SwiftUI

/// The running workout: the set to log (with the rest on top while resting), then clock / heart rate / exercise
/// navigation on the next page (Digital Crown or swipe up).
struct WorkoutPagesView: View {
    let workout: WatchWorkout

    var body: some View {
        TabView {
            SetPageView(workout: workout)
            OverviewPageView(workout: workout)
        }
        .tabViewStyle(.verticalPage)
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Clock, heart rate and previous/next exercise.
struct OverviewPageView: View {
    @Environment(WatchAppModel.self) private var app
    let workout: WatchWorkout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkoutClockText(workout: workout)
                .font(.system(.title2, design: .rounded).monospacedDigit().weight(.semibold))
            HStack(spacing: 4) {
                Image(systemName: "heart.fill").foregroundStyle(.red)
                Text(app.recorder.heartRate.map { "\(Int($0.rounded())) BPM" } ?? "-- BPM")
                    .monospacedDigit()
            }
            .font(.headline)
            .accessibilityElement(children: .combine)
            HStack {
                Button { app.workout.show(.previous) } label: { Image(systemName: "chevron.backward") }
                    .disabled(!app.workout.canShow(.previous))
                    .accessibilityLabel("Previous exercise")
                Button { app.workout.show(.next) } label: { Image(systemName: "chevron.forward") }
                    .disabled(!app.workout.canShow(.next))
                    .accessibilityLabel("Next exercise")
            }
            Text(workout.next?.exerciseName ?? workout.status)
                .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The workout's active time (pauses excluded), ticking on its own.
struct WorkoutClockText: View {
    let workout: WatchWorkout

    var body: some View {
        if let pausedAt = workout.pausedAt {
            Text(WatchFormat.clock(pausedAt.timeIntervalSince(workout.startedAt) - workout.pausedSeconds))
                .foregroundStyle(.yellow)
                .accessibilityLabel("Workout paused")
        } else {
            let start = workout.startedAt.addingTimeInterval(workout.pausedSeconds)
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
        }
    }
}
