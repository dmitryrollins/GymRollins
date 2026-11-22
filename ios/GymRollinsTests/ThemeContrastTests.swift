import Foundation
import SwiftUI
import Testing
import UIKit
@testable import GymRollins

/// Native design stage 1 (spec §3.1): Apple's dark greys, with the red action colour the app had before (the owner's
/// amendment of 17 Nov). Every colour text is drawn in keeps WCAG's 4.5:1 on the new card and page (plan 39 tuned
/// `Theme.Metric` on the old card), a label on a red action fill is white, and the badges still read.
@MainActor
@Suite struct ThemeContrastTests {
    private static let metricColours: [(String, Color)] = [
        ("workout", Theme.Metric.workout), ("time", Theme.Metric.time), ("distance", Theme.Metric.distance),
        ("calories", Theme.Metric.calories), ("heartRate", Theme.Metric.heartRate), ("power", Theme.Metric.power),
        ("cadence", Theme.Metric.cadence), ("steps", Theme.Metric.steps), ("exercise", Theme.Metric.exercise),
        ("stand", Theme.Metric.stand),
    ]

    private static let textColours: [(String, Color)] = [
        ("textPrimary", Theme.textPrimary), ("textSecondary", Theme.textSecondary),
        ("textTertiary", Theme.textTertiary), ("accent", Theme.accent), ("success", Theme.success),
        ("record", Theme.record), ("destructive", Theme.destructive), ("fatigued", RecoveryPalette.fatigued),
    ]

    @Test func everyMetricAndTextColourKeeps4_5To1OnTheCardAndThePage() {
        for (name, colour) in Self.metricColours + Self.textColours {
            for (surfaceName, surface) in [("card", Theme.card), ("background", Theme.background)] {
                let ratio = Contrast.ratio(colour, on: surface)
                #expect(ratio >= 4.5, "\(name) on \(surfaceName): \(ratio)")
            }
        }
    }

    @Test func theTokensAreApplesDarkColours() {
        #expect(Contrast.hex(Theme.background) == 0x000000)
        #expect(Contrast.hex(Theme.card) == 0x1C1C1E)
        #expect(Contrast.hex(Theme.cardInner) == 0x2C2C2E)
        #expect(Contrast.hex(Theme.divider) == 0x38383A)
        #expect(Contrast.hex(Theme.textPrimary) == 0xFFFFFF)
        #expect(Contrast.hex(Theme.textTertiary) == 0x8E8E93)
        #expect(Contrast.hex(Theme.accent) == 0xFF6B72)
        #expect(Contrast.hex(Theme.primaryFill) == 0xC22F3B)
        #expect(Contrast.hex(Theme.primaryButtonFill) == 0xA82431)
        #expect(Contrast.hex(Theme.onAccent) == 0xFFFFFF)
        #expect(Contrast.hex(Theme.Metric.workout) == 0xB6F23A, "the green-yellow stays a data colour")
        // The system's own dark red, not a hex: it moved from 0xFF453A (iOS 18) to 0xFF4245 (iOS 26).
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let systemRed = Color(uiColor: UIColor.systemRed.resolvedColor(with: dark))
        #expect(Contrast.hex(Theme.destructive) == Contrast.hex(systemRed), "system red as dark mode draws it")
        #expect(Theme.cardRadius == 24)
    }

    @Test func theAccentReadsOnEverySurface() {
        for (surfaceName, surface) in [("background", Theme.background), ("card", Theme.card),
                                       ("cardInner", Theme.cardInner)] {
            let ratio = Contrast.ratio(Theme.accent, on: surface)
            #expect(ratio >= 4.5, "accent on \(surfaceName): \(ratio)")
        }
    }

    @Test func labelsOnFilledControlsRead() {
        #expect(Contrast.ratio(Theme.onAccent, on: Theme.primaryFill) >= 4.5)
        #expect(Contrast.ratio(Theme.onAccent, on: Theme.primaryButtonFill) >= 4.5)
        // Glass lightens its tint by an amount that depends on what's behind it; white stays above 4.5:1 with 15 %
        // white mixed in.
        let lightened = Contrast.blend(Color.white.opacity(0.15), over: Contrast.opaque(Theme.primaryButtonFill))
        #expect(Contrast.ratio(Theme.onAccent, on: lightened) >= 4.5, "on the lightened glass")
        #expect(Contrast.ratio(.white, on: Theme.accent) < 4.5, "why nothing white sits on an accent fill")
        #expect(Contrast.ratio(.white, on: Theme.destructiveFill) >= 4.5)
    }

    /// `cardInner` (0x2C2C2E) is lighter than the card: system gray (`textTertiary`) is only 4.3:1 on it, so text there
    /// is primary, secondary or the accent.
    @Test func textOnTheInnerCardKeeps4_5To1() {
        for (name, colour) in [("textPrimary", Theme.textPrimary), ("textSecondary", Theme.textSecondary),
                               ("accent", Theme.accent)] {
            let ratio = Contrast.ratio(colour, on: Theme.cardInner)
            #expect(ratio >= 4.5, "\(name) on cardInner: \(ratio)")
        }
        #expect(Contrast.ratio(Theme.textTertiary, on: Theme.cardInner) < 4.5, "why the set badge isn't textTertiary")
        let badge = SetTimelineRow.badgeText(isActive: false)
        #expect(Contrast.ratio(badge, on: Theme.cardInner) >= 4.5, "a set's \"W\"/\"1\" badge")
        #expect(Contrast.ratio(SetTimelineRow.badgeText(isActive: true), on: Theme.textPrimary) >= 4.5, "the active one")
    }

    /// The Log's week strip sits on a card: a trained day's tile is the coral at 85 % under a black label, a day with
    /// only outside workouts the coral at 35 % under a white one.
    @Test func theWeekStripTilesRead() {
        let card = Contrast.opaque(Theme.card)
        for (name, tile) in [("trained", LogView.trainedTile), ("outside only", LogView.outsideTile)] {
            let fill = Contrast.blend(tile.fill, over: card)
            let ratio = Contrast.ratio(tile.label, on: fill)
            #expect(ratio >= 4.5, "\(name): \(ratio)")
        }
    }

    @Test func badgesKeepTheirContrastOnTheCard() {
        let card = Contrast.opaque(Theme.card)
        for kind in [Badge.Kind.success, .record, .neutral] {
            let fill = Contrast.blend(kind.background, over: card)
            let ratio = Contrast.ratio(kind.foreground, on: fill)
            #expect(ratio >= 4.5, "\(kind): \(ratio)")
        }
    }
}

/// WCAG 2 contrast of SwiftUI colours as dark mode draws them. A translucent colour is laid over what's under it first,
/// as the screen shows it.
private enum Contrast {
    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double
    }

    static func ratio(_ text: Color, on surface: Color) -> Double { ratio(text, on: opaque(surface)) }

    static func ratio(_ text: Color, on surface: RGB) -> Double {
        let (a, b) = (luminance(blend(text, over: surface)), luminance(surface))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `colour` over `surface`, by its opacity.
    static func blend(_ colour: Color, over surface: RGB) -> RGB {
        let resolved = resolve(colour)
        let alpha = Double(resolved.opacity)
        func mix(_ top: Float, _ bottom: Double) -> Double { Double(top) * alpha + bottom * (1 - alpha) }
        return RGB(red: mix(resolved.red, surface.red), green: mix(resolved.green, surface.green),
                   blue: mix(resolved.blue, surface.blue))
    }

    /// A surface as drawn (an opaque one is unchanged over black).
    static func opaque(_ colour: Color) -> RGB { blend(colour, over: RGB(red: 0, green: 0, blue: 0)) }

    /// 0x1C1C1E for the card, to compare a token with Apple's value.
    static func hex(_ colour: Color) -> UInt32 {
        let rgb = opaque(colour)
        func byte(_ value: Double) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return byte(rgb.red) << 16 | byte(rgb.green) << 8 | byte(rgb.blue)
    }

    private static func resolve(_ colour: Color) -> Color.Resolved {
        var environment = EnvironmentValues()
        environment.colorScheme = .dark
        return colour.resolve(in: environment)
    }

    /// WCAG's relative luminance of gamma-encoded sRGB.
    private static func luminance(_ rgb: RGB) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }
}
