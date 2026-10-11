import SwiftUI

struct SolidCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .kerning(1)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// Small colored badge, e.g. "+5 lb" (success) or "Paused" (record/amber).
struct Badge: View {
    enum Kind { case success, record, neutral }
    let text: String
    let kind: Kind

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(foreground)
            .background(background, in: .rect(cornerRadius: 6))
    }

    private var foreground: Color {
        switch kind { case .success: Theme.success; case .record: Theme.record; case .neutral: Theme.textSecondary }
    }
    private var background: Color {
        switch kind {
        case .success: Theme.successFill
        case .record: Theme.record.opacity(0.14)
        case .neutral: Theme.cardInner
        }
    }
}

/// Screen title in the condensed italic display face.
struct DisplayTitle: View {
    let text: String
    var size: CGFloat = 44
    var body: some View {
        Text(text).font(Theme.display(size)).foregroundStyle(Theme.textPrimary)
    }
}
