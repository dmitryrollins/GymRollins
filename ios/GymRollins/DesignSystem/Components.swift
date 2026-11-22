import SwiftUI

struct SolidCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
    }
}

/// A section's name above its rows, as iOS 26 Settings and Fitness draw it (spec §3.2): sentence case as written, no
/// letter-spacing, subheadline semibold in secondary text.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Small coloured badge, e.g. "+5 lb" (success) or "Paused" (record/amber). Its kinds stay; their colours follow the
/// theme (spec §3.3).
struct Badge: View {
    enum Kind {
        case success, record, neutral

        var foreground: Color {
            switch self {
            case .success: Theme.success
            case .record: Theme.record
            case .neutral: Theme.textSecondary
            }
        }

        /// Drawn over the card; the record one is a translucent amber.
        var background: Color {
            switch self {
            case .success: Theme.successFill
            case .record: Theme.record.opacity(0.14)
            case .neutral: Theme.cardInner
            }
        }
    }

    let text: String
    let kind: Kind

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(kind.foreground)
            .background(kind.background, in: .rect(cornerRadius: 6))
    }
}

/// Screen title in SF Pro bold (`Theme.display`).
struct DisplayTitle: View {
    let text: String
    var size: CGFloat = 44
    var body: some View {
        Text(text).font(Theme.display(size)).foregroundStyle(Theme.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }
}
