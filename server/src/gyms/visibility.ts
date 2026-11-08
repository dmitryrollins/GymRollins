// Who may read a gym, an item or a listing, and when a workout's link to one survives: the Postgres read policies and
// gym_link_survives / listing_link_survives (supabase/migrations/20261030000001_gyms.sql), for the app's own session.
// Claude's side is at the end (plan 29). Each fragment takes `me`, the SQL parameter that holds the
// caller's user id (such as '?2'), so a statement binds the caller wherever its other parameters leave room. The
// fragments use the aliases rg, ri, sg, si and ie inside; a query that uses them must not use those aliases itself.

export const isAdmin = (me: string) => `EXISTS (SELECT 1 FROM app_admins WHERE user_id = ${me})`

/** Whether the caller blocked this author (gym_private.is_blocked_author). */
export const blockedAuthor = (author: string, me: string) =>
  `(${author} IS NOT NULL AND EXISTS (SELECT 1 FROM user_blocks WHERE blocker_id = ${me} AND blocked_id = ${author}))`

/** A public gym while active (flagged: only to whoever added it; anything: to an admin), or your own private gym. */
export const gymReadable = (g: string, me: string) =>
  `((${g}.visibility = 'public' AND (${g}.status = 'active' OR ${isAdmin(me)} ` +
  `OR (${g}.status = 'flagged' AND ${g}.created_by = ${me}))) OR (${g}.visibility = 'private' AND ${g}.owner_id = ${me}))`

/** A link to a gym is lost when the gym is removed, or is a private gym that isn't yours. A flag doesn't cut it. */
export const gymLinkSurvives = (g: string, me: string) =>
  `(${g}.status <> 'removed' AND (${g}.visibility = 'public' OR ${g}.owner_id = ${me}))`

/**
 * A public listing by an author you haven't blocked: active under an active gym and item (flagged: only to whoever
 * added it; anything: to an admin). Or your own private listing.
 */
export const listingReadable = (e: string, me: string) =>
  `((${e}.visibility = 'public' AND NOT ${blockedAuthor(`${e}.added_by`, me)} AND (${isAdmin(me)} ` +
  `OR (${e}.status = 'active' AND EXISTS (SELECT 1 FROM gyms rg WHERE rg.id = ${e}.gym_id AND rg.status = 'active') ` +
  `AND EXISTS (SELECT 1 FROM equipment_items ri WHERE ri.id = ${e}.item_id AND ri.status = 'active')) ` +
  `OR (${e}.status = 'flagged' AND ${e}.added_by = ${me}))) OR (${e}.visibility = 'private' AND ${e}.owner_id = ${me}))`

/** A link to a listing is lost when it, its gym or its item is removed, or its author is blocked. */
export const listingLinkSurvives = (e: string, me: string) =>
  `(${e}.status <> 'removed' ` +
  `AND EXISTS (SELECT 1 FROM gyms sg WHERE sg.id = ${e}.gym_id AND sg.status <> 'removed') ` +
  `AND EXISTS (SELECT 1 FROM equipment_items si WHERE si.id = ${e}.item_id AND si.status <> 'removed') ` +
  `AND ((${e}.visibility = 'public' AND NOT ${blockedAuthor(`${e}.added_by`, me)}) ` +
  `OR (${e}.visibility = 'private' AND ${e}.owner_id = ${me})))`

/**
 * An item (equipment_items_read): never one whose creator you blocked; otherwise to an admin, to its creator, or while
 * active when it is its kind's generic item or has an active public listing you can read. In Postgres that EXISTS ran
 * under gym_equipment's own policy, so the listing must be readable too.
 */
export const itemReadable = (i: string, me: string) =>
  `(NOT ${blockedAuthor(`${i}.created_by`, me)} AND (${isAdmin(me)} OR ${i}.created_by = ${me} ` +
  `OR (${i}.status = 'active' AND ((${i}.brand IS NULL AND ${i}.model IS NULL) OR EXISTS (SELECT 1 FROM gym_equipment ie ` +
  `WHERE ie.item_id = ${i}.id AND ie.visibility = 'public' AND ie.status = 'active' AND ${listingReadable('ie', me)})))))`

/**
 * A public listing as Claude reads it (gym_equipment_read and equipment_items_read for an OAuth client, where
 * is_app_admin() is false and a flagged row never shows): active, under an active public gym, by an author
 * the owner hasn't blocked, of an active item whose creator the owner hasn't blocked. `i` is the listing's
 * item.
 */
export const claudeReadsPublicListing = (e: string, i: string, me: string) =>
  `(${e}.visibility = 'public' AND ${e}.status = 'active' AND ${i}.status = 'active' ` +
  `AND NOT ${blockedAuthor(`${e}.added_by`, me)} AND NOT ${blockedAuthor(`${i}.created_by`, me)} ` +
  'AND EXISTS (SELECT 1 FROM gyms rg ' +
  `WHERE rg.id = ${e}.gym_id AND rg.visibility = 'public' AND rg.status = 'active'))`

/**
 * One of the owner's private listings as Claude reads it, while the gyms toggle is on (the caller checks it):
 * live, with an item Claude may read (its own, or an active one whose creator isn't blocked).
 */
export const claudeReadsPrivateListing = (e: string, i: string, me: string) =>
  `(${e}.visibility = 'private' AND ${e}.owner_id = ${me} AND ${e}.status = 'active' ` +
  `AND ${e}.deleted_at IS NULL ` +
  `AND NOT ${blockedAuthor(`${i}.created_by`, me)} AND (${i}.created_by = ${me} OR ${i}.status = 'active'))`
