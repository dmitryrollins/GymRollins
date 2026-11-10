import GymData
import SwiftUI

/// Step 4's "Who sees it": one row per option the gym offers. "This phone only" is selected until the user chooses
/// otherwise.
struct GymVisibilityPicker: View {
    let options: [GymVisibility]
    @Binding var selection: GymVisibility

    static func title(_ option: GymVisibility) -> String {
        switch option {
        case .device: "This phone only"
        case .shared: "Shared at this gym"
        case .synced: "Synced to my account"
        }
    }

    static func detail(_ option: GymVisibility) -> String {
        switch option {
        case .device: "Stays on this phone. Nothing is uploaded."
        case .shared: "People who train here can see it and confirm it. Needs an account."
        case .synced: "Backed up to your account, for your other devices. Only you see it."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Who sees it")
            ForEach(options, id: \.self) { option in row(option) }
        }
    }

    private func row(_ option: GymVisibility) -> some View {
        let selected = option == selection
        return Button { selection = option } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.primaryFill : Theme.textTertiary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(option)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    Text(Self.detail(option)).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: Theme.minTapSize, alignment: .leading)
            .padding(12).background(Theme.card, in: .rect(cornerRadius: 14)).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("add.visibility.\(option.rawValue)")
    }
}
