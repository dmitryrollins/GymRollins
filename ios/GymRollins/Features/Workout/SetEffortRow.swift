import GymCore
import SwiftUI

/// Chip titles and VoiceOver labels for the "Reps left?" row.
enum SetEffortText {
    static func title(_ choice: Int) -> String { choice == SetEffort.choices.last ? "\(choice)+" : "\(choice)" }

    static func accessibilityLabel(_ choice: Int) -> String {
        switch choice {
        case 0: "0 reps left, failure"
        case 1: "1 rep left"
        case SetEffort.choices.last: "\(choice) or more reps left"
        default: "\(choice) reps left"
        }
    }
}

/// "Reps left?" 0 · 1 · 2 · 3 · 4+ under a logged working set: one optional tap rates how hard it was (reps in
/// reserve), tapping the selected chip clears it. Purely a rating — it never logs, rests or moves on. Chips are 44 pt
/// targets with `<prefix>.<n>` identifiers and the selected trait.
struct SetEffortRow: View {
    let rir: Double?
    var identifierPrefix = "set.effort"
    let onTap: (Int) -> Void

    private var selected: Int? { SetEffort.choice(for: rir) }

    var body: some View {
        // One line when it fits; at large text sizes the chips wrap under the label instead of clipping.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                label
                Spacer(minLength: 4)
                chips
            }
            VStack(alignment: .leading, spacing: 6) {
                label
                FlowLayout(spacing: 6) { chips }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var label: some View {
        Text("Reps left?")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize()
            .accessibilityIdentifier("\(identifierPrefix).label")
    }

    private var chips: some View {
        ForEach(SetEffort.choices, id: \.self) { chip($0) }
    }

    private func chip(_ choice: Int) -> some View {
        let isSelected = selected == choice
        return Button { onTap(choice) } label: {
            Text(SetEffortText.title(choice))
                .font(Theme.display(17, heavy: isSelected))
                .foregroundStyle(isSelected ? Theme.background : Theme.textPrimary)
                .frame(minWidth: Theme.minTapSize, minHeight: Theme.minTapSize)
                .background(isSelected ? Theme.textPrimary : Theme.cardInner, in: .capsule)
                .overlay { Capsule().strokeBorder(isSelected ? Color.clear : Theme.divider, lineWidth: 1) }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SetEffortText.accessibilityLabel(choice))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("\(identifierPrefix).\(choice)")
    }
}
