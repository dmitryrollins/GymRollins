/// Which row of the Claude screen's Use with Claude and Ready requests sections was copied last: only that row reads
/// "Copied". The copy goes through `write` (the pasteboard in the app), so tests see the exact text.
struct UseWithClaudeModel: Equatable {
    static let coachId = "coach"

    private(set) var copiedId: String?

    func isCopied(_ id: String) -> Bool { copiedId == id }

    mutating func copy(_ id: String, text: String, to write: (String) -> Void) {
        write(text)
        copiedId = id
    }
}
