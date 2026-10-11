import GymCore
import SwiftUI

/// Body tab: "Strength level" for squat, bench press and deadlift against raw powerlifting competitors. Rows open
/// the lift's history (through `openHistory`: several `NavigationLink`s in one `List` row would all fire on a tap);
/// the info button opens the method sheet; missing inputs show what to add.
struct StrengthLevelCard: View {
    @Environment(AppEnvironment.self) private var env
    /// Called with the exercise id whose history to push.
    let openHistory: (String) -> Void
    @State private var report: StrengthReport?
    @State private var showMethod = false
    @State private var showProfile = false

    private var unit: WeightUnit { env.profile.unit }

    var body: some View {
        SolidCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    SectionLabel(text: "Strength level").accessibilityIdentifier("body.strength")
                    Spacer()
                    Button { showMethod = true } label: {
                        Image(systemName: "info.circle").foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(HitAreaButtonStyle(horizontalPadding: 0))
                    .accessibilityLabel("How strength levels work")
                    .accessibilityIdentifier("body.strength.info")
                }
                if let report {
                    content(report)
                } else {
                    Text("Strength levels are unavailable right now.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        // Data/profile edits, foregrounding, midnight and a periodic tick: the 365-day window and the age move
        // with time even when nothing is edited.
        .insightsRefresh { report = env.strengthReport() }
        .sheet(isPresented: $showMethod) {
            StrengthMethodSheet(report: report).presentationDetents([.large])
        }
        .sheet(isPresented: $showProfile) {
            StrengthProfileSheet().presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func content(_ report: StrengthReport) -> some View {
        if let missing = StrengthText.missing(report.missing) {
            Text(missing).font(.footnote).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("body.strength.missing")
            if report.missing.contains(.profile) {
                GlassPillButton(title: "Add sex & birth year", systemImage: "person.crop.circle.badge.plus",
                                identifier: "body.strength.addProfile") { showProfile = true }
            }
        }
        ForEach(report.rows) { row in
            Button { openHistory(row.estimate?.exerciseId ?? row.lift.primaryExerciseId) } label: {
                StrengthLevelRow(row: row, unit: unit).contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("body.strength.\(row.lift.rawValue)")
        }
        Text("Compared with raw powerlifting competitors of your sex, age group and bodyweight.")
            .font(.caption).foregroundStyle(Theme.textTertiary)
    }
}
