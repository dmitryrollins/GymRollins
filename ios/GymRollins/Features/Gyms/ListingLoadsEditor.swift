import GymCore
import SwiftUI

/// The loads control for one kind of equipment: a stepper for a weight stack's top, chips for a fixed set, nothing
/// for the rest. Identifiers are `<idPrefix>.stackMinus`, `.stackPlus`, `.stackValue`, `.weight.<kg>`, `.weightsAll`.
struct ListingLoadsEditor: View {
    @Binding var loads: ListingLoads
    let kind: EquipmentKind
    let unit: WeightUnit
    let idPrefix: String

    private var editing: ListingLoadsEditing { ListingLoadsEditing(kind: kind, unit: unit, loads: loads) }

    var body: some View {
        let editing = editing
        if let stack = editing.stackText {
            stackControl(editing, text: stack)
        } else if editing.kind.load == .fixedSet {
            chips(editing)
        }
    }

    private func stackControl(_ editing: ListingLoadsEditing, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Top of the stack")
            HStack(spacing: 12) {
                Button { loads = editing.steppedStack(-1) } label: { Image(systemName: "minus") }
                    .glassCircle().disabled(!editing.canDecrement)
                    .accessibilityLabel("Lower the top weight")
                    .accessibilityIdentifier("\(idPrefix).stackMinus")
                Text(text).font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity).accessibilityIdentifier("\(idPrefix).stackValue")
                Button { loads = editing.steppedStack(1) } label: { Image(systemName: "plus") }
                    .glassCircle().disabled(!editing.canIncrement)
                    .accessibilityLabel("Raise the top weight")
                    .accessibilityIdentifier("\(idPrefix).stackPlus")
            }
        }
    }

    private func chips(_ editing: ListingLoadsEditing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Weights here")
            FlowLayout {
                chip("All", selected: editing.allSelected, identifier: "\(idPrefix).weightsAll") {
                    loads = editing.togglingAll()
                }
                ForEach(editing.options) { option in
                    chip(option.label, selected: editing.isSelected(option.kg),
                         identifier: "\(idPrefix).weight.\(WeightFormatter.number(option.tag))") {
                        loads = editing.toggled(option.kg)
                    }
                }
            }
            if !editing.isValid {
                Text("Pick at least one weight.").font(.footnote).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func chip(_ title: String, selected: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color.white : Theme.textPrimary)
                .padding(.horizontal, 12).frame(minHeight: Theme.minTapSize)
                .background(selected ? Theme.primaryFill : Theme.cardInner, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
