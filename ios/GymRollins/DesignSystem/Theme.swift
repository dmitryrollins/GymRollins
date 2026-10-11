import SwiftUI

/// Tokens from docs/design/STYLE.md.
enum Theme {
    static let background = Color(hex: 0x0B0B10)
    static let card = Color(hex: 0x17171E)
    static let cardInner = Color(hex: 0x262631)
    static let divider = Color(hex: 0x25252E)
    static let textPrimary = Color(hex: 0xF2F2F5)
    static let textSecondary = Color(hex: 0xA9A9B5)
    static let textTertiary = Color(hex: 0x8E8E9A)
    static let accent = Color(hex: 0xFF6B72)
    /// Prominent-button fill. Darker than the mockup's 0xD63A46 so white labels on the (slightly lightened) glass
    /// tint stay above 4.5:1 (accessibility audit: contrast).
    static let primaryFill = Color(hex: 0xC22F3B)
    static let success = Color(hex: 0x4FD1A5)
    static let successFill = Color(hex: 0x14342A)
    static let record = Color(hex: 0xF5B75A)
    static let destructive = Color(hex: 0xFF8A8F)

    static let cardRadius: CGFloat = 18
    static let gutter: CGFloat = 20

    /// Condensed italic display face for screen/sheet titles and big numbers. Scales with Dynamic Type relative to
    /// the text style closest to `size` (a small number scaled like `.largeTitle` would barely grow).
    static func display(_ size: CGFloat, heavy: Bool = true) -> Font {
        .custom(heavy ? "BarlowCondensed-ExtraBoldItalic" : "BarlowCondensed-BoldItalic", size: size,
                relativeTo: textStyle(forSize: size))
    }

    /// The Dynamic Type text style whose default size is closest to (and not above) `size`.
    static func textStyle(forSize size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<12: .caption2
        case ..<13: .caption
        case ..<15: .footnote
        case ..<16: .subheadline
        case ..<20: .body
        case ..<22: .title3
        case ..<28: .title2
        case ..<34: .title
        default: .largeTitle
        }
    }

    /// Minimum tappable size (HIG / accessibility audit hit region).
    static let minTapSize: CGFloat = 44
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
