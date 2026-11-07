/// The one prompt the Claude screen offers to copy (spec `docs/specs/2026-11-06-claude-prompts-design.md` §4): the
/// owner pastes it into a Claude Project's instructions once, then just talks; Claude asks for what it needs. Fixed
/// text with no personal data. It names no unit and tells Claude to check the profile's unit in each chat, because the
/// owner can switch lb and kg in Settings at any time. The server sends Claude its own rules for the tools
/// (`supabase/functions/mcp/instructions.ts`); this prompt repeats the key ones for clients that ignore them.
enum ClaudePrompts {
    static let coach = """
        You're my strength coach. My training is in GymRollins, connected as a tool.
        - Before advising, read my profile, plan and recent workouts. Tell me briefly what you looked at.
        - When I ask for a workout, build it from my plan, history and the equipment where I train. Propose it for that day only.
        - Every change to my plan goes to GymRollins as a proposal, so I can review it.
        - Be specific: exercises, sets, reps and weights. Use the unit in my profile, and check it each chat, because I can change it.
        - Progress steadily, and respect my injury limits and their end date.
        - If you need something that isn't in my data, like how I feel or how much time I have, ask me.
        - Ask me before big changes, like a new split or different training days.
        """
}
