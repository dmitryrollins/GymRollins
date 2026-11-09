// Claude's own hosts: the approve sheet shows a connection returning to one without a warning (routes.ts), and the
// agents list marks an agent whose callback is on one as known (agents.ts). One set, so the two can't drift.
export const CLAUDE_HOSTS: ReadonlySet<string> = new Set(['claude.ai', 'claude.com'])

/** What proposals.from_agent and workouts.added_by hold at most (migrations/0011_ai_agents.sql). */
const LABEL_MAX = 64
const LOOPBACK_HOST = /^(localhost|127\.0\.0\.1)(:\d{1,5})?$/

/** A redirect URL's host as the approve sheet has it (src/claude/connect-page.ts), or '' when it isn't a URL. */
export function hostOf(uri: string | null): string {
  if (uri === null) return ''
  try {
    return new URL(uri).host
  } catch {
    return ''
  }
}

/**
 * The name an agent's proposals and workouts carry (plan 32, added after review). On Claude's own hosts it is the
 * registered name; on any other host the host goes beside it ("Muse (agent.meta.ai)", "Claude Code (local)" for the
 * owner's own computer), because any client can register any name, "Claude" included. The host alone when the name is
 * missing or the two don't fit in 64 characters; null when there is neither.
 */
export function agentLabel(name: string | null, firstRedirectUri: string | null): string | null {
  const named = name !== null && name.length >= 1 && name.length <= LABEL_MAX ? name : null
  const host = hostOf(firstRedirectUri)
  if (host === '') return named
  if (CLAUDE_HOSTS.has(host)) return named ?? host
  const where = LOOPBACK_HOST.test(host) ? 'local' : host
  const both = named === null ? where : `${named} (${where})`
  return both.length <= LABEL_MAX ? both : where.slice(0, LABEL_MAX)
}
