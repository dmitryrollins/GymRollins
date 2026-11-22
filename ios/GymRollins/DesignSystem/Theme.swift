import SwiftUI
import UIKit

/// Design tokens (native design stage 1, spec §3): Apple's dark system colours and Fitness' larger card corners, with
/// the red action colour the app had before stage 1 (the owner's amendment of 17 Nov; Fitness' green-yellow stays a
/// data colour, `Metric.workout`). The app is dark-only. The system colours are taken in their dark appearance once,
/// because the Live Activity compiles this file and draws on a fixed black background, even on a light lock screen.
enum Theme {
    /// Fitness' page.
    static let background = Color(hex: 0x000000)
    /// Apple's dark secondary grouped background.
    static let card = Color(hex: 0x1C1C1E)
    /// Apple's dark tertiary grouped background.
    static let cardInner = Color(hex: 0x2C2C2E)
    /// Apple's opaque dark separator.
    static let divider = Color(hex: 0x38383A)
    static let textPrimary = Color.white
    /// Apple's `secondaryLabel` (60 % 0xEBEBF5): 5.9:1 on `card`.
    static let textSecondary = dark(.secondaryLabel)
    /// System gray, not `tertiaryLabel`: its 30 % is under 4.5:1 and fails the accessibility audit. 5.2:1 on `card`.
    static let textTertiary = Color(hex: 0x8E8E93)
    /// The coral for tints, links, toggles, the selected tab, and accent text and icons on the page and cards: 7.6:1 on
    /// `background`, 6.2:1 on `card` and 5.0:1 on `cardInner`. White on it is only 2.8:1, so nothing white or
    /// text-bearing sits on an `accent` fill; a fill behind a label is `primaryFill` or `primaryButtonFill`.
    static let accent = Color(hex: 0xFF6B72)
    /// White, the label and symbol colour on the red action fills (`primaryFill`, `primaryButtonFill`). Never used on
    /// `accent`, where white is only 2.8:1.
    static let onAccent = Color.white
    /// A solid red fill behind a white label (a chosen chip or weight): white on it is 5.6:1. Darker than the old
    /// mockup's 0xD63A46 for that reason.
    static let primaryFill = Color(hex: 0xC22F3B)
    /// The prominent glass tint (`prominentGlass()`, `PrimaryGlassButton`): white on it is 7.1:1. Glass lightens a tint
    /// by an amount that depends on what is behind it (over a form, `primaryFill` dipped just under 4.5:1), and this
    /// keeps white above 5:1 even with 15 % white mixed in.
    static let primaryButtonFill = Color(hex: 0xA82431)
    static let success = Color(hex: 0x4FD1A5)
    static let successFill = Color(hex: 0x14342A)
    static let record = Color(hex: 0xF5B75A)
    /// Apple's destructive colour (system red, 0xFF4245 in dark on iOS 26): 5.0:1 on `card`.
    static let destructive = dark(.systemRed)
    /// A solid fill behind a white destructive symbol (a set's swipe Delete): white is 5.6:1 on it, 3.4:1 on system red.
    static let destructiveFill = Color(hex: 0xC22F3B)

    /// Fitness' card corners.
    static let cardRadius: CGFloat = 24
    static let gutter: CGFloat = 20

    /// Screen and sheet titles (spec §3.2): SF Pro bold at the Dynamic Type style `textStyle(forSize:)` picks for the
    /// old `size` (44 and 34 → large title 34 pt, 28 → title 28 pt, 22–27 → title2 22 pt), so they keep scaling with
    /// the text size.
    static func display(_ size: CGFloat) -> Font {
        .system(textStyle(forSize: size), design: .default, weight: .bold)
    }

    /// Big numbers (stat tiles, weights, clocks): SF Rounded semibold, as plan 39's `MetricSize` fonts, at the same text
    /// style `display` picks. `heavy` (the active set, a chosen chip) is bold.
    static func number(_ size: CGFloat, heavy: Bool = false) -> Font {
        .system(textStyle(forSize: size), design: .rounded, weight: heavy ? .bold : .semibold)
    }

    /// The largest Dynamic Type text style whose default size is at most `size`, capped at large title (44 → large
    /// title, 34 pt). Callout is skipped (16 → body, 17 pt), and anything under 11 is caption2.
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

    /// `color` as dark mode draws it, fixed.
    private static func dark(_ color: UIColor) -> Color {
        Color(uiColor: color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
