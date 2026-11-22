import SwiftUI

/// "Strength" (spec §4): the app's own Exercises, Sets and Volume in plain text and Records in amber. Workout Time,
/// which this grid's Duration tile showed before, is in Workout Details.
struct WorkoutStrengthCard: View {
    let readings: [MetricReading]

    var body: some View {
        DetailSection(title: "Strength", titleIdentifier: "detail.strength.title") {
            MetricGrid(readings: readings, prefix: "detail")
        }
    }
}
