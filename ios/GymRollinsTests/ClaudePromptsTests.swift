import Testing
@testable import GymRollins

@Suite struct ClaudePromptsTests {
    @Test func theCoachPromptIsEightLinesWithNoPersonalDetails() {
        let lines = ClaudePrompts.coach.split(separator: "\n")
        #expect(lines.count == 8)
        #expect(lines.first == "You're my strength coach. My training is in GymRollins, connected as a tool.")
        #expect(!ClaudePrompts.coach.contains { $0.isNumber })
    }

    @Test func itBuildsWorkoutsAsProposalsForOneDay() {
        #expect(ClaudePrompts.coach.contains("When I ask for a workout, build it from my plan, history and the equipment"))
        #expect(ClaudePrompts.coach.contains("Propose it for that day only."))
        #expect(ClaudePrompts.coach.contains("goes to GymRollins as a proposal"))
    }

    @Test func itNamesNoUnitAndChecksItEachChat() {
        #expect(ClaudePrompts.coach.contains("check it each chat, because I can change it"))
        #expect(!ClaudePrompts.coach.contains(" lb"))
        #expect(!ClaudePrompts.coach.contains(" kg"))
    }

    @Test func itAsksForWhatTheDataDoesNotHave() {
        #expect(ClaudePrompts.coach.contains("If you need something that isn't in my data"))
    }
}
