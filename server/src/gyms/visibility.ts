// Who may read a gym or a listing, and when a workout's link to one survives: the Postgres read policies and
// gym_link_survives / listing_link_survives (supabase/migrations/20261030000001_gyms.sql), for the app's own session.
// Plan 29 adds Claude's side (the mcp_read_gyms toggle). Each fragment reads the caller's user id as ?2.

const IS_ADMIN = 'EXISTS (SELECT 1 FROM app_admins WHERE user_id = ?2)'
const blockedAuthor = (author: string) =>
  `(${author} IS NOT NULL AND EXISTS (SELECT 1 FROM user_blocks WHERE blocker_id = ?2 AND blocked_id = ${author}))`

/** A public gym while active (flagged: only to whoever added it; anything: to an admin), or your own private gym. */
export const gymReadable = (g: string) =>
  `((${g}.visibility = 'public' AND (${g}.status = 'active' OR ${IS_ADMIN} ` +
  `OR (${g}.status = 'flagged' AND ${g}.created_by = ?2))) OR (${g}.visibility = 'private' AND ${g}.owner_id = ?2))`

/** A link to a gym is lost when the gym is removed, or is a private gym that isn't yours. A flag doesn't cut it. */
export const gymLinkSurvives = (g: string) =>
  `(${g}.status <> 'removed' AND (${g}.visibility = 'public' OR ${g}.owner_id = ?2))`

/**
 * A public listing by an author you haven't blocked: active under an active gym and item (flagged: only to whoever
 * added it; anything: to an admin). Or your own private listing.
 */
export const listingReadable = (e: string) =>
  `((${e}.visibility = 'public' AND NOT ${blockedAuthor(`${e}.added_by`)} AND (${IS_ADMIN} ` +
  `OR (${e}.status = 'active' AND EXISTS (SELECT 1 FROM gyms rg WHERE rg.id = ${e}.gym_id AND rg.status = 'active') ` +
  `AND EXISTS (SELECT 1 FROM equipment_items ri WHERE ri.id = ${e}.item_id AND ri.status = 'active')) ` +
  `OR (${e}.status = 'flagged' AND ${e}.added_by = ?2))) OR (${e}.visibility = 'private' AND ${e}.owner_id = ?2))`

/** A link to a listing is lost when it, its gym or its item is removed, or its author is blocked. */
export const listingLinkSurvives = (e: string) =>
  `(${e}.status <> 'removed' ` +
  `AND EXISTS (SELECT 1 FROM gyms sg WHERE sg.id = ${e}.gym_id AND sg.status <> 'removed') ` +
  `AND EXISTS (SELECT 1 FROM equipment_items si WHERE si.id = ${e}.item_id AND si.status <> 'removed') ` +
  `AND ((${e}.visibility = 'public' AND NOT ${blockedAuthor(`${e}.added_by`)}) ` +
  `OR (${e}.visibility = 'private' AND ${e}.owner_id = ?2)))`
