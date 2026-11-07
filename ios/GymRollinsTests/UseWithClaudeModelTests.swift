import Testing
@testable import GymRollins

@Suite struct UseWithClaudeModelTests {
    @Test func nothingIsMarkedBeforeACopy() {
        #expect(UseWithClaudeModel().copiedId == nil)
    }

    @Test func copyWritesTheExactTextAndMarksThatRow() {
        var model = UseWithClaudeModel()
        var written: [String] = []
        model.copy(UseWithClaudeModel.coachId, text: ClaudePrompts.coach) { written.append($0) }
        #expect(written == [ClaudePrompts.coach])
        #expect(model.isCopied(UseWithClaudeModel.coachId))
        #expect(!model.isCopied("tomorrow"))
    }

    @Test func aSecondCopyMovesTheMark() {
        var model = UseWithClaudeModel()
        var written: [String] = []
        model.copy(UseWithClaudeModel.coachId, text: ClaudePrompts.coach) { written.append($0) }
        model.copy("weight", text: "Log my weight today: __ kg") { written.append($0) }
        #expect(written.last == "Log my weight today: __ kg")
        #expect(model.isCopied("weight"))
        #expect(!model.isCopied(UseWithClaudeModel.coachId))
    }
}
