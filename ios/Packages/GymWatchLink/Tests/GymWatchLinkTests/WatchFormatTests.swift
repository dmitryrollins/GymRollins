import Foundation
import Testing
@testable import GymWatchLink

@Suite struct WatchFormatTests {
    @Test func weights() {
        #expect(WatchFormat.weight(135) == "135")
        #expect(WatchFormat.weight(62.5) == "62.5")
        #expect(WatchFormat.weight(134.922) == "134.9")
        #expect(WatchFormat.weight(134.99) == "135")
        #expect(WatchFormat.weight(0) == "0")
    }

    @Test func clocks() {
        #expect(WatchFormat.clock(5) == "0:05")
        #expect(WatchFormat.clock(90.9) == "1:30")
        #expect(WatchFormat.clock(3_723) == "1:02:03")
        #expect(WatchFormat.clock(-3) == "0:00")
        #expect(WatchFormat.countdown(0.2) == "0:01")
        #expect(WatchFormat.countdown(89.5) == "1:30")
    }
}
