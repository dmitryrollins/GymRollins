import GymCore
import Testing
@testable import GymRollins

@Suite struct ClaudePromptsTests {
    @Test func theCoachPromptIsSixLinesWithNoPersonalDetails() {
        let lines = ClaudePrompts.coach.split(separator: "\n")
        #expect(lines.count == 6)
        #expect(lines.first == "You're my strength coach. My training is in GymRollins, connected as a tool.")
        #expect(ClaudePrompts.coach.contains("check it each chat, because I can change it"))
        #expect(!ClaudePrompts.coach.contains { $0.isNumber })
    }

    @Test func theRequestsComeInTheAgreedOrder() {
        let requests = ClaudePrompts.requests(unit: .lb)
        #expect(requests.map(\.id) == ["tomorrow", "week", "lastWorkout", "home", "muscles", "stronger", "weight"])
        #expect(requests.first?.text == "Plan my workout for tomorrow.")
        #expect(requests[5].text == "Am I getting stronger? Compare my main lifts with a month ago.")
    }

    @Test func theWeightRequestUsesTheUnitItIsGiven() {
        #expect(ClaudePrompts.requests(unit: .lb).last?.text == "Log my weight today: __ lb")
        #expect(ClaudePrompts.requests(unit: .kg).last?.text == "Log my weight today: __ kg")
    }

    @Test func onlyTheWeightRequestDependsOnTheUnit() {
        let pairs = zip(ClaudePrompts.requests(unit: .lb), ClaudePrompts.requests(unit: .kg))
        #expect(pairs.filter { $0 != $1 }.map(\.0.id) == ["weight"])
    }
}
