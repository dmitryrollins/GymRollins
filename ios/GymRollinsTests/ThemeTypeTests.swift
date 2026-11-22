import Foundation
import SwiftUI
import Testing
@testable import GymRollins

/// Native design stage 1 (spec §3.2): titles in SF Pro bold and numbers in SF Rounded semibold, both at the Dynamic
/// Type style the old size maps to, so they keep scaling; the Barlow face is gone from the app and its credits.
@Suite struct ThemeTypeTests {
    @Test func titlesAreSFProBoldAtTheTextStyleForTheirSize() {
        #expect(Theme.display(44) == .system(.largeTitle, design: .default, weight: .bold))
        #expect(Theme.display(34) == .system(.largeTitle, design: .default, weight: .bold))
        #expect(Theme.display(28) == .system(.title, design: .default, weight: .bold))
        #expect(Theme.display(22) == .system(.title2, design: .default, weight: .bold))
    }

    @Test func numbersAreSFRoundedSemiboldAndBoldWhenHeavy() {
        #expect(Theme.number(56) == .system(.largeTitle, design: .rounded, weight: .semibold))
        #expect(Theme.number(26) == .system(.title2, design: .rounded, weight: .semibold))
        #expect(Theme.number(15) == .system(.subheadline, design: .rounded, weight: .semibold))
        #expect(Theme.number(28, heavy: true) == .system(.title, design: .rounded, weight: .bold))
    }

    @Test func barlowIsNoLongerShippedOrCredited() throws {
        #expect(Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") == nil)
        let url = try #require(Bundle.main.url(forResource: "CREDITS", withExtension: "md"))
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("Barlow"))
    }
}
