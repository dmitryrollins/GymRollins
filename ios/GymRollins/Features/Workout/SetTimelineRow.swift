import GymCore
import SwiftUI
import UIKit

/// One row in the logging timeline: a hexagon badge (warm-up "W", working index, or a done check)
/// and two editable boxes whose kind depends on the exercise mode (reps/weight, seconds/weight, or
/// minutes/distance). The active set gets floating labels and, for barbell exercises, a
/// "Bar + Plates" caption under the weight.
///
/// Stateless on purpose: the text shown in each box and keyboard focus are owned by the logging
/// screen (`text(for:)` returns a binding into its draft dictionary; `focus` is its single
/// `@FocusState`), so rebuilding this row after a session update can never reset a draft or drop
/// focus, and merely displaying a set never writes it back.
struct SetTimelineRow: View {
    let set: WorkoutSet
    /// 0-based position within the entry, warm-ups included; drives the `logging.set.<index>.*` ids.
    let index: Int
    /// Warm-up or working number (the badge shows "W" or the working index).
    let ordinal: SetOrdinal
    let isActive: Bool
    let mode: ExerciseMode
    let unit: WeightUnit
    let isBarbell: Bool
    let text: (SetField) -> Binding<String>
    var focus: FocusState<SetField?>.Binding
    /// Today's plan before the workout (no done / current status).
    var isPlanned = false
    /// Long-press menu on the badge (and VoiceOver actions): nil hides the item.
    var onRemove: (() -> Void)?
    var onToggleWarmup: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            hexBadge
            // At accessibility text sizes two boxes side by side can't fit the scaled numbers, so they stack.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                ForEach(SetFieldFormat.fields(for: mode, setId: set.id), id: \.self) { field in
                    box(field)
                }
            }
        }
    }

    private var summary: String {
        SetAccessibilityText.rowLabel(set: set, ordinal: ordinal, mode: mode, unit: unit, isActive: isActive,
                                      isPlanned: isPlanned)
    }

    private var warmupToggleTitle: String { self.set.warmup ? "Make Working Set" : "Make Warm-up Set" }

    private var ordinalName: String {
        switch ordinal {
        case .warmup(let n): "warm-up set \(n)"
        case .working(let n): "set \(n)"
        }
    }

    /// The badge glyph ("W", "1", a check) is hidden from VoiceOver; its slot carries the row's spoken summary
    /// ("Set 1, 8 reps, 140 pounds, done"), read before the row's editable boxes.
    private var hexBadge: some View {
        ZStack {
            HexagonShape().fill(badgeFill)
            if set.done && !isActive {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .black)).foregroundStyle(Theme.success)
            } else {
                Text(ordinal.workingPosition.map(String.init) ?? "W")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(badgeText)
            }
        }
        .frame(width: 28, height: 26)
        .accessibilityHidden(true)
        .overlay {
            Color.clear
                .accessibilityElement()
                .accessibilityLabel(summary)
                .accessibilityIdentifier("logging.set.\(index).summary")
                .accessibilityActions {
                    if let onToggleWarmup { Button(warmupToggleTitle, action: onToggleWarmup) }
                    if let onRemove { Button("Remove Set", action: onRemove) }
                }
        }
        .contentShape(.rect)
        .contextMenu {
            if let onToggleWarmup {
                Button(warmupToggleTitle, systemImage: "flame", action: onToggleWarmup)
                    .accessibilityIdentifier("logging.set.warmupToggle")
            }
            if let onRemove {
                Button("Remove Set", systemImage: "trash", role: .destructive, action: onRemove)
                    .accessibilityIdentifier("logging.set.remove")
            }
        }
        .padding(.top, isActive ? 8 : 6)
    }

    private var badgeFill: Color {
        if isActive { return Theme.textPrimary }
        if set.done { return Theme.successFill }
        return Theme.cardInner
    }

    private var badgeText: Color { isActive ? Theme.background : Theme.textTertiary }

    private func caption(_ field: SetField) -> String? {
        guard case .weight = field, isActive else { return nil }
        if isBarbell { return "Bar + Plates" }
        return set.multiplier == 2 ? "Per Arm" : nil
    }

    private func box(_ field: SetField) -> some View {
        let label = SetFieldFormat.label(field, warmup: set.warmup, unit: unit)
        return VStack(alignment: .leading, spacing: 4) {
            if isActive {
                Text(label).font(.caption2.weight(.bold)).foregroundStyle(Theme.textPrimary)
                    .accessibilityHidden(true) // the field's own label says it
            }
            TextField(label, text: text(field))
                .keyboardType(SetFieldFormat.isDecimal(field) ? .decimalPad : .numberPad)
                .multilineTextAlignment(.center)
                .font(Theme.display(isActive ? 28 : 20, heavy: isActive))
                .foregroundStyle(!isActive && set.done ? Theme.textTertiary : Theme.textPrimary)
                .padding(.horizontal, 6)
                // Minimum (not fixed) heights so scaled text never clips.
                .frame(maxWidth: .infinity, minHeight: isActive ? 58 : Theme.minTapSize)
                .background(isActive ? Color.clear : Theme.cardInner.opacity(0.6), in: .rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isActive ? Theme.textPrimary : Theme.divider, lineWidth: isActive ? 1.5 : 1)
                }
                .focused(focus, equals: field)
                .accessibilityLabel("\(label), \(ordinalName)")
                .accessibilityIdentifier("logging.set.\(index).\(field.identifierSuffix)")
            if let caption = caption(field) {
                Text(caption).font(.caption2).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Hexagon badge shape (matches the mockup's clip-path hexagon).
struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.25, y: 0))
        p.addLine(to: CGPoint(x: w * 0.75, y: 0))
        p.addLine(to: CGPoint(x: w, y: h * 0.5))
        p.addLine(to: CGPoint(x: w * 0.75, y: h))
        p.addLine(to: CGPoint(x: w * 0.25, y: h))
        p.addLine(to: CGPoint(x: 0, y: h * 0.5))
        p.closeSubpath()
        return p
    }
}
