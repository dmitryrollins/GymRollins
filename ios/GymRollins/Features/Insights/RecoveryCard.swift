import GymCore
import SwiftUI

/// "Muscle recovery" summary card (Today and the Body tab): summary line, a small front/back figure and the
/// freshest groups. The whole card opens the full map.
struct RecoveryCard: View {
    @Environment(AppEnvironment.self) private var env
    /// Accessibility identifier prefix, e.g. "today.recovery" or "body.recovery".
    let identifier: String
    @State private var snapshot = InsightsSnapshot.empty

    var body: some View {
        NavigationLink {
            RecoveryMapView()
        } label: {
            SolidCard {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "Muscle recovery")
                        Text(snapshot.summaryLine)
                            .font(.headline).foregroundStyle(Theme.textPrimary)
                            .accessibilityIdentifier("\(identifier).summary")
                        if let fresh = snapshot.freshLine {
                            Text(fresh).font(.subheadline).foregroundStyle(Theme.success)
                                .accessibilityIdentifier("\(identifier).fresh")
                        }
                        if !snapshot.limited.isEmpty {
                            Text("Legs limited by your injury note")
                                .font(.footnote).foregroundStyle(Theme.textSecondary)
                        }
                        Text("See muscle map \u{203A}").font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        BodyMapView(side: .front, snapshot: snapshot)
                        BodyMapView(side: .back, snapshot: snapshot)
                    }
                    .frame(height: 104)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the muscle recovery map")
        .accessibilityIdentifier(identifier)
        .insightsRefresh { snapshot = env.insights() }
    }
}
