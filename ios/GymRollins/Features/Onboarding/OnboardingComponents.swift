import SwiftUI

/// Small caps step dots ("Step N of 3"), glass pill, top-right of Profile Setup / Import CSV / Connect Claude.
struct OnboardingProgressDots: View {
    /// 1...3
    let step: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...3, id: \.self) { i in
                Circle().fill(i == step ? Theme.accent : Color.white.opacity(0.25)).frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassCapsule(interactive: false)
    }
}

/// Glass circle back chevron, top-left of every onboarding step but Welcome.
struct OnboardingBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left").font(.headline).foregroundStyle(Theme.textPrimary)
        }
        .glassCircle()
        .accessibilityLabel("Back")
        .accessibilityIdentifier("onboarding.back")
    }
}

/// Glass segmented control shared by units / training days / experience on Profile Setup. Segments share the width
/// equally; when a label wouldn't fit its share (large Dynamic Type, long labels like "Intermediate"), the options
/// stack vertically instead of truncating.
struct GlassSegmentedControl<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var identifierPrefix: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            EqualWidthSegments { segments(fixedLabels: true) }
            VStack(spacing: 2) { segments(fixedLabels: false) }
        }
        .padding(2)
        .glassCapsule(interactive: false)
    }

    private func segments(fixedLabels: Bool) -> some View {
        ForEach(options, id: \.value) { option in
            Button { selection = option.value } label: {
                Text(option.label)
                    .font(.subheadline.weight(selection == option.value ? .bold : .semibold))
                    .foregroundStyle(selection == option.value ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(fixedLabels ? 1 : nil)
                    .fixedSize(horizontal: fixedLabels, vertical: true)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: Theme.minTapSize)
                    .background(selection == option.value ? Color.white.opacity(0.12) : Color.clear,
                               in: .rect(cornerRadius: 22))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityAddTraits(selection == option.value ? .isSelected : [])
            .accessibilityIdentifier(identifierPrefix.map { "\($0).\(option.label)" } ?? option.label)
        }
    }
}

/// Lays subviews out in a row of equal widths (2 pt apart). Its ideal width is what the widest subview needs times the
/// count, so `ViewThatFits` falls back to the stacked layout exactly when some label couldn't fit an equal share.
private struct EqualWidthSegments: Layout {
    let spacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let widest = ideal.map(\.width).max() ?? 0
        let needed = widest * CGFloat(subviews.count) + spacing * CGFloat(subviews.count - 1)
        let width = proposal.width.map { max($0, needed) } ?? needed
        let height = ideal.map(\.height).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let count = CGFloat(subviews.count)
        let width = (bounds.width - spacing * (count - 1)) / count
        for (index, subview) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index) * (width + spacing)
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}

/// Labeled uppercase caption above a form control, matching STYLE.md's small-caps label tokens.
struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.bold)).kerning(0.8).foregroundStyle(Theme.textTertiary)
    }
}
