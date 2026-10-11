import Foundation
import Testing
@testable import GymRollins

@Suite struct ClaudeConnectionBadgeTests {
    /// Default (signed out, permissions on by default) is "Not connected": flags aren't a connection.
    @Test func signedOutIsNotConnected() {
        let badge = ClaudeConnectionBadge.make(signedIn: false, checked: false, lastUse: nil)
        #expect(badge == .notConnected)
        #expect(badge.text == "Not connected")
        #expect(badge.kind == .neutral)
    }

    @Test func signedInFollowsLastMcpUse() {
        #expect(ClaudeConnectionBadge.make(signedIn: true, checked: false, lastUse: nil) == .checking)
        #expect(ClaudeConnectionBadge.make(signedIn: true, checked: true, lastUse: nil) == .notConnected)
        let used = ClaudeConnectionBadge.make(signedIn: true, checked: true, lastUse: Date(timeIntervalSince1970: 1))
        #expect(used == .connected)
        #expect(used.text == "Connected")
        #expect(used.kind == .success)
    }
}
