import GymCore
import SwiftUI

/// Body tab: hard sets per muscle group this week against the target range (bar = sets vs the top of the range,
/// with the range marked).
struct WeeklySetsCard: View {
    @Environment(AppEnvironment.self) private var env
    @State private var snapshot = InsightsSnapshot.empty

    var body: some View {
        SolidCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "Weekly sets").accessibilityIdentifier("body.weeklySets")
                    Spacer()
                    Text(snapshot.weekLabel).font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                ForEach(snapshot.weeklyRows) { row in
                    WeeklySetsRow(row: row)
                }
                Text("Hard sets (warm-ups excluded); an exercise's secondary muscles count half. Edit targets in "
                     + "Settings \u{203A} Weekly targets.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .insightsRefresh { snapshot = env.insights() }
    }
}

struct WeeklySetsRow: View {
    let row: WeeklyMuscleSets

    private var tint: Color {
        switch row.status {
        case .below: Theme.textSecondary
        case .within: Theme.success
        case .above: Theme.record
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.group.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(WeeklySets.format(row.sets)) / \(row.target.text)")
                    .font(.footnote.monospacedDigit()).foregroundStyle(tint)
            }
            GeometryReader { geo in
                let width = geo.size.width
                let top = Double(max(row.target.max, 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cardInner)
                    Rectangle().fill(Theme.success.opacity(0.18))
                        .frame(width: width * CGFloat(Double(row.target.max - row.target.min) / top))
                        .offset(x: width * CGFloat(Double(row.target.min) / top))
                    Capsule().fill(tint).frame(width: max(0, width * CGFloat(row.fraction)))
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(InsightsSnapshot.weeklyAccessibility(row))
        .accessibilityIdentifier("body.weeklySets.\(row.group.rawValue)")
    }
}
