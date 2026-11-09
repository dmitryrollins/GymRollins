// The name an agent's proposals and workouts carry (plan 32, review): Claude's own hosts show the registered name; any
// other shows its host beside it, so a client that registers as "Claude" elsewhere can't pass for Claude.
import { describe, expect, it } from 'vitest'
import { agentLabel } from '../src/claude/hosts.ts'

describe('agentLabel', () => {
  it.each([
    ['Claude', 'https://claude.ai/api/mcp/auth_callback', 'Claude'],
    ['Claude', 'https://claude.com/api/mcp/auth_callback', 'Claude'],
    ['Muse', 'https://agent.meta.ai/api/hatch/oauth/callback', 'Muse (agent.meta.ai)'],
    ['Claude', 'https://agent.meta.ai/cb', 'Claude (agent.meta.ai)'],
    ['Claude Code', 'http://127.0.0.1:33418/callback', 'Claude Code (local)'],
    ['Claude Code', 'http://localhost:61234/callback', 'Claude Code (local)'],
    [null, 'https://agent.meta.ai/cb', 'agent.meta.ai'],
    [null, 'http://127.0.0.1:33418/callback', 'local'],
    [null, 'https://claude.ai/api/mcp/auth_callback', 'claude.ai'],
    ['N'.repeat(60), 'https://agent.meta.ai/cb', 'agent.meta.ai'],
    ['Muse', 'https://' + 'a'.repeat(60) + '.example/cb', ('a'.repeat(60) + '.example').slice(0, 64)],
    ['Muse', null, 'Muse'],
    [null, null, null],
    ['Muse', 'not a url', 'Muse'],
  ])('%s with %s is %s', (name, uri, label) => {
    expect(agentLabel(name, uri)).toBe(label)
  })
})
