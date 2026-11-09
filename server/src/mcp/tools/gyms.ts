// list_gyms and get_gym_equipment: read-only views of the owner's gyms for Claude, behind mcp_flag('gyms').
// Strangers' free text is a path for prompt injection, so every result is built from an allow-list of keys (never by
// spreading a row): no user ids, no notes, brand and model only where the owner wrote the words, `loads` rebuilt from
// known keys, and a public gym's name labelled unverified and cut down to visible characters. Which exercises work at a gym follows GymCore's InventoryMatcher:
// every requirement group needs a listing of one of its kinds, read from public.exercise_requirements (the table the
// app's bundled JSON seeds, with a drift check), so there is no copy to keep in step.
import type { Db, GymListingRow, GymRow } from '../db.ts'
import { compact, ok, type ToolCtx, ToolError, type ToolResult } from './result.ts'

export const PRIVATE_GYMS_MAX = 100
export const PUBLIC_GYMS_MAX = 100
export const GYM_LIST_MAX = PRIVATE_GYMS_MAX + PUBLIC_GYMS_MAX
/** gymActiveListingsMax: a gym holds at most this many active listings. */
export const GYM_LISTINGS_MAX = 300
const MAX_FIXED_WEIGHTS = 60

async function requireGymsOn(db: Db): Promise<void> {
  if (!(await db.readPermissions()).gyms) {
    throw new ToolError(
      'Reading gyms is turned off: the owner can switch it on under AI agents in the GymRollins app.',
    )
  }
}

/** Private gyms, then public gyms the owner trained at or shared to; the only gyms Claude can name. */
async function visibleGyms(db: Db): Promise<GymRow[]> {
  const [mine, shared] = await Promise.all([
    db.privateGyms(PRIVATE_GYMS_MAX),
    db.myPublicGyms(PUBLIC_GYMS_MAX),
  ])
  return [...mine, ...shared]
}

export const GYM_NAME_MAX = 60

// Letters, marks, numbers, punctuation and symbols are kept; spaces, format characters, private use and the rest are
// not. Some invisible characters are letters or marks (the Hangul fillers, the variation selectors, the combining
// grapheme joiner), so those are listed too. The database refuses them in names; this is for rows older than that rule.
const KEPT = /[\p{L}\p{M}\p{N}\p{P}\p{S}]/u
const INVISIBLE = /[\u034F\u115F\u1160\u17B4\u17B5\u180B-\u180F\u3164\uFE00-\uFE0F\uFFA0\u{E0100}-\u{E01EF}]/u

/** A stranger's gym name as Claude may read it: visible characters only, single spaces, at most 60 characters. */
export function normalizeGymName(name: string): string {
  let out = ''
  for (const ch of name) {
    if (/\s/u.test(ch)) out += ' '
    else if (KEPT.test(ch) && !INVISIBLE.test(ch)) out += ch
  }
  return Array.from(out.replace(/ {2,}/g, ' ').trim()).slice(0, GYM_NAME_MAX).join('').trim()
}

function gymSummary(g: GymRow) {
  const isPrivate = g.visibility === 'private'
  return compact({
    id: g.id,
    visibility: isPrivate ? 'private' : 'public',
    ...(isPrivate ? { name: g.name } : { name_unverified: normalizeGymName(g.name) }),
    // The first sharer wrote a public gym's address; it is the owner's own text only for a gym they created.
    address: isPrivate || g.is_mine ? g.address : null,
  })
}

export async function listGyms({ db }: ToolCtx): Promise<ToolResult> {
  await requireGymsOn(db)
  const gyms = (await visibleGyms(db)).map(gymSummary)
  return ok({ count: gyms.length, gyms })
}

const isNum = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

/** `loads` rebuilt from the keys each type is known to have; anything else is dropped. */
export function rebuildLoads(loads: unknown): Record<string, unknown> | undefined {
  if (typeof loads !== 'object' || loads === null || Array.isArray(loads)) return undefined
  const l = loads as Record<string, unknown>
  switch (l.type) {
    case 'plates':
      return { type: 'plates' }
    case 'stack':
      return compact({
        type: 'stack',
        max_kg: isNum(l.maxKg) ? l.maxKg : null,
        step_kg: isNum(l.stepKg) ? l.stepKg : null,
      })
    case 'fixed':
      return { type: 'fixed', kg: Array.isArray(l.kg) ? l.kg.filter(isNum).slice(0, MAX_FIXED_WEIGHTS) : [] }
    default:
      return undefined // 'none' and anything unknown
  }
}

function listingSummary(l: GymListingRow) {
  // A private listing's brand and model are the owner's own words (private_brand, private_model). A public listing's come
  // from the shared item, which may be a stranger's even when the listing is the owner's, so they show only if the owner
  // also wrote the item.
  const own = l.is_mine === true && (l.visibility === 'private' || l.item_is_mine === true)
  return compact({
    kind_id: typeof l.kind_id === 'string' ? l.kind_id : null,
    quantity: isNum(l.quantity) ? l.quantity : null,
    confirm_count: isNum(l.confirm_count) ? l.confirm_count : null,
    visibility: l.visibility === 'private' ? 'private' : 'public',
    loads: rebuildLoads(l.loads),
    brand: own && typeof l.brand === 'string' ? l.brand : null,
    model: own && typeof l.model === 'string' ? l.model : null,
  })
}

/** Exercise ids whose every requirement group has a listing of one of its kinds (no groups = no equipment). */
function availableExerciseIds(
  requirements: { exercise_id: string; groups: unknown }[],
  kinds: Set<string>,
): string[] {
  const ids: string[] = []
  for (const r of requirements) {
    if (!Array.isArray(r.groups)) continue // unmapped, like InventoryMatcher
    const groups = r.groups as unknown[]
    const wellFormed = groups.every((g) => Array.isArray(g) && g.every((k) => typeof k === 'string'))
    if (wellFormed && groups.every((g) => (g as string[]).some((k) => kinds.has(k)))) ids.push(r.exercise_id)
  }
  return ids.sort()
}

export async function getGymEquipment({ db }: ToolCtx, args: { gym_id: string }): Promise<ToolResult> {
  await requireGymsOn(db)
  // The same set list_gyms offers: a public gym the owner never used answers like one that doesn't exist.
  const gym = (await visibleGyms(db)).find((g) => g.id === args.gym_id)
  if (!gym) throw new ToolError('Gym not found. Use list_gyms to find gym ids.')
  const [rows, requirements] = await Promise.all([
    db.gymListings(gym.id, GYM_LISTINGS_MAX + 1),
    db.exerciseRequirements(),
  ])
  const truncated = rows.length > GYM_LISTINGS_MAX
  const listings = rows.slice(0, GYM_LISTINGS_MAX)
  const ids = availableExerciseIds(requirements, new Set(listings.map((l) => l.kind_id)))
  const { id, visibility, name, name_unverified } = gymSummary(gym) as Record<string, string>
  return ok(compact({
    gym: compact({ id, visibility, name, name_unverified }),
    listings: listings.map(listingSummary),
    truncated: truncated ? true : null,
    exercise_count: ids.length,
    exercise_ids: ids,
  }))
}
