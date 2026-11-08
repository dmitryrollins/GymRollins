import { Refusals } from '../gyms/refusals.ts'
import { badRequest, uuidOf } from '../http/input.ts'

// What a report, a block or a moderation names: a public gym or listing. Clients never see user ids, so a block names
// a gym or listing and the server finds its author. Items aren't targets: everything visible about one comes through
// a listing, and removing that listing takes its text out of the catalogue.

export type TargetType = 'gym' | 'listing'

export interface Target {
  readonly type: TargetType
  readonly id: string
}

export interface PublicTarget {
  readonly author: string | null
  readonly status: 'active' | 'flagged' | 'removed'
}

export const TARGET_TABLE: Readonly<Record<TargetType, string>> = { gym: 'gyms', listing: 'gym_equipment' }
const AUTHOR: Readonly<Record<TargetType, string>> = { gym: 'created_by', listing: 'added_by' }

/** `{target_type, target_id}` of a body. Any type but gym or listing names nothing: 'unknown target'. */
export function targetOf(body: Record<string, unknown>): Target {
  const id = uuidOf(body.target_id, 'target_id')
  if (typeof body.target_type !== 'string') throw badRequest('target_type must be text.')
  if (body.target_type !== 'gym' && body.target_type !== 'listing') throw Refusals.unknownTarget()
  return { type: body.target_type, id }
}

/** gym_private.public_target: the author and status of a public gym or listing, which the caller needn't see. */
export async function publicTarget(db: D1Database, target: Target): Promise<PublicTarget> {
  const row = await db.prepare(
    `SELECT ${AUTHOR[target.type]} AS author, status FROM ${TARGET_TABLE[target.type]} ` +
      "WHERE id = ?1 AND visibility = 'public'",
  ).bind(target.id).first<PublicTarget>()
  if (!row) throw Refusals.unknownTarget()
  return row
}
