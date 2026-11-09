// What a tool tells an agent when the owner turned a read switch off (owner, 2026-11-09). The data layer still
// answers as if the rows were hidden (src/mcp/d1-db.ts), so a tool that only returned what it read would look like an
// empty history. Each tool checks the switches it needs first: one it can't answer without refuses with these words,
// and a tool that still answers in part says what it withheld.
import type { Db } from '../db.ts'
import { ToolError } from './result.ts'

export type ReadSwitch = 'workouts' | 'body' | 'plan' | 'gyms'

/** The switches as the app names them in Settings › AI agents. */
const SWITCH_NAMES: Readonly<Record<ReadSwitch, string>> = {
  workouts: 'Read workouts and sets',
  body: 'Read bodyweight',
  plan: 'Read your plan and profile',
  gyms: 'Gyms',
}

/** “A”, “A” and “B”, or “A”, “B” and “C”. */
function named(switches: readonly ReadSwitch[]): string {
  const names = switches.map((s) => `“${SWITCH_NAMES[s]}”`)
  return names.length === 1 ? names[0]! : `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`
}

const WHERE = 'for agents in the GymRollins app (Settings › AI agents)'

export function notAllowed(off: readonly ReadSwitch[]): string {
  return `Not allowed: the owner has turned off ${named(off)} ${WHERE}, so nothing was read. ` +
    'This is not an empty result: tell the owner, who can turn it on.'
}

export function withheld(off: readonly ReadSwitch[], what: string): string {
  return `${what} withheld: the owner has turned off ${named(off)} ${WHERE}.`
}

/** Which of `needed` the owner turned off, in the order given. */
export async function switchedOff(db: Db, ...needed: ReadSwitch[]): Promise<ReadSwitch[]> {
  const allowed = await db.readPermissions()
  return needed.filter((s) => !allowed[s])
}

/** Refuses, naming every switch in `needed` that is off; returns when all are on. */
export async function requireReads(db: Db, ...needed: ReadSwitch[]): Promise<void> {
  const off = await switchedOff(db, ...needed)
  if (off.length > 0) throw new ToolError(notAllowed(off))
}
