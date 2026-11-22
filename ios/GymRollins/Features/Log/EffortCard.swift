import GymCore
import SwiftUI

/// "Effort" on the workout detail (spec §4): the rating as a number and its word, the Apple Watch's estimate marked
/// "Estimated", or a glass Add Effort pill; tapping the value or the pill opens the Effort sheet. While the effort types
/// were never asked for (Health turned on by build 4), a glass Allow pill asks (spec §5.2); a rating Health should have
/// taken and didn't says so (spec §5.4).
struct EffortCard: View {
    let effort: Effort?
    let needsAsking: Bool
    let notInHealth: Bool
    let onOpen: () -> Void
    let onAllow: () -> Void

    var body: some View {
        DetailSection(title: "Effort") {
            VStack(alignment: .leading, spacing: 12) {
                if let effort {
                    value(effort)
                } else {
                    GlassPillButton(title: "Add Effort", systemImage: "plus.circle", identifier: "detail.addEffort",
                                    action: onOpen)
                }
                if needsAsking { allowRow }
                if notInHealth {
                    Label(MeasuredText.effortNotInHealth, systemImage: "exclamationmark.triangle")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.destructive)
                        .accessibilityIdentifier("detail.effort.healthError")
                }
            }
        }
    }

    /// "6 Moderate" in SF Rounded with a chevron; one button VoiceOver reads as "Effort, 6 out of 10, Moderate".
    private func value(_ effort: Effort) -> some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Text(MeasuredText.effort(effort))
                    .font(Theme.number(20)).foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
            }
            .frame(minHeight: Theme.minTapSize)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Effort")
        .accessibilityValue(MeasuredText.spokenEffort(effort))
        .accessibilityHint("Opens the effort scale")
        .accessibilityIdentifier("detail.effort")
    }

    /// The note and the Allow pill side by side while they fit, else stacked (accessibility text sizes).
    private var allowRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                allowNote
                Spacer(minLength: 0)
                allowButton
            }
            VStack(alignment: .leading, spacing: 8) {
                allowNote
                allowButton
            }
        }
    }

    private var allowNote: some View {
        Text(MeasuredText.effortAllowNote).font(.footnote).foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var allowButton: some View {
        GlassPillButton(title: "Allow", identifier: "detail.effort.allow", action: onAllow)
    }
}
