import Foundation
import Testing
@testable import GymRollins

@Suite struct ExerciseWebSearchTests {
    @Test func searchesGoogleForHowToDoTheExercise() throws {
        let url = ExerciseWebSearch.url(for: "Dumbbell Pullover")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "www.google.com")
        #expect(components.path == "/search")
        #expect(components.queryItems == [URLQueryItem(name: "q", value: "how to do Dumbbell Pullover")])
    }

    @Test func encodesSymbolsInTheName() {
        let url = ExerciseWebSearch.url(for: "3/4 Sit-Up & Twist")
        #expect(url.absoluteString == "https://www.google.com/search?q=how%20to%20do%203/4%20Sit-Up%20%26%20Twist")
    }
}
