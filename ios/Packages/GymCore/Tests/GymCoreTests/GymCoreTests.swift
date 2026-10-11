import Testing
@testable import GymCore

@Suite struct GymCoreSmokeTests {
    @Test func versionIsSet() {
        #expect(GymCore.version == "0.1.0")
    }
}
