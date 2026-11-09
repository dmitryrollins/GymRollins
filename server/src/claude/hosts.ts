// Claude's own hosts: the approve sheet shows a connection returning to one without a warning (routes.ts), and the
// agents list marks an agent whose callback is on one as known (agents.ts). One set, so the two can't drift.
export const CLAUDE_HOSTS: ReadonlySet<string> = new Set(['claude.ai', 'claude.com'])
