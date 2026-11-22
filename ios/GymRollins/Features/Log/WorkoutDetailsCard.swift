import GymCore
import GymHealth
import SwiftUI

/// "Workout Details" (spec §4): Workout Time, Active and Total Calories, Avg. and Max Heart Rate in Fitness' colours,
/// or the estimate with its ⓘ method sheet when Health measured nothing; under it, what measured it and whether the
/// workout is in Apple Health.
struct WorkoutDetailsCard: View {
    let summary: MeasuredSummary
    let estimate: CalorieEstimate?
    let healthStatus: HealthSync.ExportStatus
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailSection(title: "Workout Details") {
                if summary.source == .estimate {
                    Button { showInfo = true } label: { Image(systemName: "info.circle") }
                        .glassCircle()
                        .accessibilityLabel("How calories are estimated")
                        .accessibilityIdentifier("detail.kcal.info")
                }
            } content: {
                MetricGrid(readings: MeasuredText.details(summary,
                                                          usedDefaultBodyWeight: estimate?.usedDefaultBodyWeight ?? false),
                           prefix: "detail")
            }
            footnote
        }
        .sheet(isPresented: $showInfo) { CalorieInfoSheet(estimate: estimate) }
    }

    /// "Measured by Apple Watch · Saved to Apple Health" on one line while it fits, else on two.
    private var footnote: some View {
        let line = MeasuredText.healthSave(healthStatus)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                measuredBy
                if let line {
                    Text("\u{00B7}").foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
                    healthLabel(line)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                measuredBy
                if let line { healthLabel(line) }
            }
        }
        .font(.footnote)
    }

    private var measuredBy: some View {
        Text(MeasuredText.measuredBy(summary.source))
            .foregroundStyle(Theme.textSecondary)
            .accessibilityIdentifier("detail.measuredBy")
    }

    private func healthLabel(_ line: HealthSaveLine) -> some View {
        Label(line.text, systemImage: line.symbol)
            .fontWeight(.semibold)
            .foregroundStyle(line.color)
            .accessibilityIdentifier("detail.health")
    }
}

extension HealthSaveLine {
    /// Saving in secondary text, saved in green, a failure in red.
    var color: Color {
        switch self {
        case .saving: Theme.textSecondary
        case .saved: Theme.success
        case .failed: Theme.destructive
        }
    }
}
