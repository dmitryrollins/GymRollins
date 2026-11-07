import GymCore

/// What the Claude screen offers to copy (spec `docs/specs/2026-11-06-claude-prompts-design.md` §4): the coach prompt
/// for a Claude Project's instructions, and ready requests to paste into a chat there. Fixed texts with no personal
/// data. No unit is kept: the weight request is built from the unit it's given on every draw, because the owner can
/// switch lb and kg in Settings at any time. The server sends Claude its own rules (`supabase/functions/mcp/
/// instructions.ts`); the coach prompt repeats the key ones for clients that ignore them.
enum ClaudePrompts {
    struct Request: Equatable, Identifiable, Sendable {
        let id: String
        let text: String
    }

    static let coach = """
        You're my strength coach. My training is in GymRollins, connected as a tool.
        - Before advising, read my profile, plan and recent workouts. Tell me briefly what you looked at.
        - Be specific: exercises, sets, reps and weights. Use the unit in my profile, and check it each chat, because I can change it.
        - Progress steadily, and respect my injury limits and their end date.
        - To change my plan, propose it in GymRollins so I can review it. A session for one day goes on that date only.
        - Ask me before big changes, like a new split or different training days.
        """

    static func requests(unit: WeightUnit) -> [Request] {
        [
            Request(id: "tomorrow", text: "Plan my workout for tomorrow."),
            Request(id: "week", text: "How did my last week go?"),
            Request(id: "lastWorkout", text: "Review my last workout."),
            Request(id: "home", text: "Plan a home session with the equipment I have at home."),
            Request(id: "muscles", text: "Which muscles am I under-training?"),
            Request(id: "stronger", text: "Am I getting stronger? Compare my main lifts with a month ago."),
            Request(id: "weight", text: "Log my weight today: __ \(unit.rawValue)"),
        ]
    }
}
