import GymCore
import SwiftUI

/// The Effort sheet (spec §4), glass like the plate calculator: a 1–10 scale of glass pills with Apple's words (Easy
/// 1–3, Moderate 4–6, Hard 7–8, All Out 9–10), the chosen one tinted red; the chosen score large in the accent with
/// its word; Save and Cancel; and Clear Rating when the workout has a rating (not only the Apple Watch's estimate).
struct EffortSheet: View {
    let canClear: Bool
    let onSave: (Int) -> Void
    let onClear: () -> Void
    @State private var score: Int?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Opens on the workout's effort, rated or estimated.
    init(effort: Effort?, canClear: Bool, onSave: @escaping (Int) -> Void, onClear: @escaping () -> Void) {
        self.canClear = canClear
        self.onSave = onSave
        self.onClear = onClear
        _score = State(initialValue: effort?.score)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    DisplayTitle(text: "Effort", size: 28)
                    Spacer()
                    GlassPillButton(title: "Cancel", identifier: "effort.cancel") { dismiss() }
                }
                chosen
                scale
                Text(MeasuredText.effortKey())
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("effort.key")
                PrimaryGlassButton(title: "Save", identifier: "effort.save") {
                    guard let score else { return }
                    onSave(score)
                    dismiss()
                }
                .disabled(score == nil)
                if canClear {
                    SecondaryGlassButton(title: "Clear Rating", identifier: "effort.clear") {
                        onClear()
                        dismiss()
                    }
                }
            }
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.medium, .large])
    }

    /// "6" large in the accent over "Moderate"; a question before a score is chosen.
    private var chosen: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let score {
                Text(score.formatted()).font(Theme.number(44)).foregroundStyle(Theme.accent)
                Text(MeasuredText.effortWord(score) ?? "").font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            } else {
                Text("How hard was it?").font(.title3.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("effort.chosen")
    }

    /// Two rows of five; five rows of two at accessibility text sizes, so "10" never clips or sits alone in a row.
    private var scale: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 2 : 5)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Effort.range, id: \.self) { value in scoreButton(value) }
        }
    }

    /// A glass pill; the chosen one is the prominent glass, tinted the red action colour with a white number.
    private func scoreButton(_ value: Int) -> some View {
        let selected = value == score
        let button = Button { score = value } label: {
            Text(value.formatted())
                .font(Theme.number(20, heavy: selected))
                .foregroundStyle(selected ? Theme.onAccent : Theme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: Theme.minTapSize)
        }
        // Two styles, so the chosen pill is swapped rather than morphed: only `.glassProminent` fills solid red under
        // the white number, while a tinted `.regular` glass is see-through and would dim it (owner rule: glass stays).
        return Group {
            if selected { button.prominentGlass() } else { button.buttonStyle(.glass) }
        }
        .accessibilityLabel(MeasuredText.spokenScore(value))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("effort.score.\(value)")
    }
}
