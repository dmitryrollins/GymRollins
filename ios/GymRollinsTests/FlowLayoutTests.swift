import CoreGraphics
import Testing
@testable import GymRollins

@Suite struct FlowLayoutTests {
    @Test func keepsItemsOnOneLineWhileTheyFit() {
        #expect(FlowLayout.lines(widths: [100, 100, 100], maxWidth: 400, spacing: 8) == [[0, 1, 2]])
    }

    @Test func wrapsBeforeTheItemThatWouldOverflow() {
        // 100 + 8 + 120 + 8 + 150 = 386 fits 390; the 4th (87) would not.
        #expect(FlowLayout.lines(widths: [100, 120, 150, 87], maxWidth: 390, spacing: 8) == [[0, 1, 2], [3]])
    }

    @Test func anItemWiderThanTheLineGetsItsOwnLine() {
        #expect(FlowLayout.lines(widths: [50, 500, 50], maxWidth: 300, spacing: 8) == [[0], [1], [2]])
        #expect(FlowLayout.lines(widths: [], maxWidth: 300, spacing: 8).isEmpty)
    }
}
