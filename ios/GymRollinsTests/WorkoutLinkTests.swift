import Foundation
import GymCore
import Testing
@testable import GymRollins

@Suite struct WorkoutLinkTests {
    private let workout = SharedWorkout(items: [SharedWorkout.Item(exerciseId: "0025", sets: 3,
                                                                    target: .reps(min: 8, max: 10))])
    private let web = WorkoutLink(host: "gym.example")
    private let noHost = WorkoutLink(host: nil)

    @Test func makesAnAppLinkWithNoHost() {
        #expect(noHost.url(for: workout)?.absoluteString == "gymrollins://w#1.0025_3_8-10")
    }

    @Test func makesAWebLinkWithAHost() {
        #expect(web.url(for: workout)?.absoluteString == "https://gym.example/w#1.0025_3_8-10")
    }

    @Test(arguments: ["", "   "])
    func aBlankHostMeansNone(host: String) {
        #expect(WorkoutLink(host: host) == noHost)
    }

    /// The setting and the scheme reach the app. It doesn't pin the value: the owner sets it once the domain exists.
    @Test func theSettingAndTheSchemeReachTheApp() throws {
        let host = try #require(Bundle.main.object(forInfoDictionaryKey: "SHARE_LINK_HOST") as? String)
        #expect(!host.contains("$("))
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        #expect(types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains(WorkoutLink.scheme) == true })
    }

    @Test(arguments: ["gymrollins://w#1.0025_3_10", "GYMROLLINS://w#1.0025_3_10", "https://gym.example/w#1.0025_3_10",
                      "https://gym.example/w/#1.0025_3_10", "https://GYM.example/w#1.0025_3_10"])
    func readsBothKinds(text: String) throws {
        #expect(web.payload(in: try #require(URL(string: text))) == "1.0025_3_10")
    }

    @Test func aBuildWithNoHostStillReadsAppLinks() throws {
        #expect(noHost.payload(in: try #require(URL(string: "gymrollins://w#1.0025_3_10"))) == "1.0025_3_10")
    }

    @Test(arguments: ["https://evil.example/w#1.0025_3_10", "https://gym.example.evil.example/w#1.0025_3_10",
                      "http://gym.example/w#1.0025_3_10", "https://gym.example/x#1.0025_3_10",
                      "https://gym.example/w/x#1.0025_3_10", "https://gym.example/w", "gymrollins://x#1.0025_3_10",
                      "gymrollins://w/x#1.0025_3_10", "gymrollins://w", "other://w#1.0025_3_10",
                      "https://me@gym.example/w#1.0025_3_10", "https://gym.example:8443/w#1.0025_3_10",
                      "https://gym.example/w?a=1#1.0025_3_10"])
    func refusesEverythingElse(text: String) throws {
        #expect(web.payload(in: try #require(URL(string: text))) == nil)
    }

    @Test func aBuildWithNoHostRefusesEveryWebLink() throws {
        #expect(noHost.payload(in: try #require(URL(string: "https://gym.example/w#1.0025_3_10"))) == nil)
    }
}
