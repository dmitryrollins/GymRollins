import SwiftUI

/// A section of a screen rebuilt in Fitness' layout (spec §3.3): its title in bold title3 above a solid card, with an
/// optional control at the header's end (the estimate's ⓘ).
struct DetailSection<Accessory: View, Content: View>: View {
    let title: String
    /// The title's accessibility identifier, for UI tests and the audit's exclusions.
    var titleIdentifier: String?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.title3.bold()).foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(titleIdentifier ?? "")
                Spacer(minLength: 0)
                accessory
            }
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        }
    }
}

extension DetailSection where Accessory == EmptyView {
    init(title: String, titleIdentifier: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, titleIdentifier: titleIdentifier, accessory: { EmptyView() }, content: content)
    }
}
