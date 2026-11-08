# Plan 28: Gyms, photos and moderation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The local Worker in `server/` serves everything the app does with gyms today:
- private gyms and their listings in sync,
- the shared catalogue: reads, finding or creating a gym, sharing and confirming a listing,
- reports, blocks and the admin queue,
- gym photos in R2, private and shared,
- the public photo routes, including GymRollins' own exercise photos and their `manifest.json`.

Every daily limit and cap keeps its number and its error code, and account deletion keeps working with photos. Then
the app uses all of it: the catalogue, moderation and photos through `ApiGymCatalogTransport`, private gyms in sync,
exercise photos from the Worker, and the gym suites on a throwaway Worker.

**Architecture:**
- **Sync.** Gyms and listings join the plan-26 entity machinery. `Entity` gains an owner column (`owner_id`), a pull
  scope (`visibility = 'private'`), insert-only columns, a per-row `prepare` and a pull shape.
- **Caps** on private rows are SQLite triggers that `RAISE`, so a whole push fails at once, as the Postgres triggers did.
- **Daily limits** are part of the statement or batch that writes: `INSERT … SELECT … WHERE (count) < N`. When nothing
  was written, one read afterwards says why. D1 runs writes one at a time, so there are no locks.
- **Visibility** reuses `src/gyms/visibility.ts`, now with the caller's parameter, plus the item read rule.
- **Text rules** (`clean_text`), trimming, case folding and the loads shape are TypeScript. D1's CHECKs keep the
  control-character and length parts.
- **Photos** are R2 objects with a `photo_objects` row each. The row is claimed first, in one conditional statement
  holding every rule, then the object is written. A delete removes the object first, then the row.

**Tech stack:** as plan 26 (Hono 4.13.17, Better Auth 1.7.18, D1 and R2 through wrangler 4.158.0, Vitest 4.1.12 with
`@cloudflare/vitest-plugin` 1.6.0 in workerd). R2 runs locally in the tests, as D1 does.

**Spec:** `docs/specs/2026-11-07-cloudflare-backend-design.md`, sections 3 (routes, storage, type mapping), 4 ("Gyms,
photos and moderation"), 6, 7 and 8.

**Ported from:**
- `supabase/migrations/20261030000001_gyms.sql` … `20261030000006_gym_moderation.sql`,
- `20260929000001_exercise_photos_bucket.sql`,
- `supabase/functions/_shared/domain-limits.ts`,
- the pgTAP files `gyms`, `gym_rules`, `gym_review_fixes`, `gym_moderation`, `gym_photo_guard`, `exercise_photos_bucket`
  and the gym parts of `security` (every behaviour they check has a server test below).

**Branch:** `feat-cloudflare`, on top of plans 26 and 27. The server part needs only plan 26; the iOS part needs plan 27.
- No push.
- Local only: never run `wrangler login`, `wrangler deploy`, or any `wrangler` command without `--local`.
- Commit messages have no `Co-Authored-By`, `Generated with` or `Claude-Session` trailers; the owner forbids them.

**Two parts:** the server (Tasks 1–10), then the iOS side (Tasks 11–18), which builds on plan 27.

**Not in this plan:**
- Claude's reads of gyms (`mcp_read_gyms`), which is plan 29.
- The remote R2 buckets, the deploy and removing Supabase, which are plan 30 and the owner's steps.

The Supabase code keeps working beside `server/` until plan 30.

---

## Decisions this plan makes

1. **Caps are triggers** (`migrations/0005_gyms_photos.sql`):
   - 100 live private gyms and 1,000 live private listings per user.
   - **Checked by probe in workerd:**
     - `wrangler d1 migrations apply --local` and the tests' `applyD1Migrations` both apply `CREATE TRIGGER … BEGIN … END;`.
     - A `BEFORE INSERT` trigger's count sees the rows the same statement wrote before it.
     - `RAISE(ABORT, 'too_many_gyms')` fails the whole statement, and the whole batch around it. The error message
       is `D1_ERROR: too_many_gyms: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_TRIGGER)`.
     - The `BEFORE INSERT` trigger also fires for an upsert row that turns into an update, as Postgres's did.
   - `onError` turns these into `422 too_many_gyms` / `too_many_listings`. A multi-row push can't use "insert only if
     under the limit", because that would skip rows silently instead of refusing them.
2. **Daily limits** are one conditional statement or one batch, as the spec says. The count sits in the `WHERE` of the
   insert. If nothing was written, a read afterwards names the reason, in the order the Postgres function checked.
   A race can only change which refusal code is given; it can never let a row past a limit.
3. **Case folding.** `equipment_items` gains `brand_key` and `model_key`, which hold `foldKey(brand)` and
   `foldKey(model)` (JavaScript's `toLowerCase`). The unique identity index moves to them.
   - SQLite's `lower()` folds ASCII only (probe: `lower('ÄÖÜ')` stays `ÄÖÜ`), so `Ä` and `ä` would be two items.
   - A CHECK keeps a key beside every brand and model.
4. **Text.**
   - `clean_text` is ported to `src/gyms/text.ts`, code point for code point.
   - **Found by probe:** D1 stores U+0000 in bound text, and SQLite's `length()` stops at it, so a NUL slips past
     every length CHECK. Postgres refused NUL outright. Every `text` column, plan 26's too, now refuses U+0000 and
     half of a UTF-16 pair (which D1 stores as invalid UTF-8).
   - Trimming is `btrim`'s: spaces only.
5. **Loads** are checked by `parseLoads` (exact keys, numbers within the limits) and stored as compact JSON rebuilt
   from the checked values.
   - Postgres's "24 characters or fewer" rule then always holds for what is stored.
   - An input that Postgres refused only for its spelling (`1.0000000000000000000001`) is now taken as the rounded
     number. A null `stepKg` is dropped; the app decodes both forms.
6. **Photos.**
   - **Upload:** a pending `photo_objects` row is claimed first, by one conditional insert holding every rule (the
     owner exists, no listing uses the name, under 60 today). Then the R2 put. If the put fails, the row goes, unless
     the object exists by then.
   - **Delete:** the object first, then the row, so no object is ever left that nobody owns.
   - **An unfinished upload** (a row with no object: the Worker stopped in between) still counts, is listed by
     `GET /v1/photos/mine`, and is finished by its owner uploading the same name again.
   - **A repeated name answers 409** before the daily limit is looked at, so a retry after a lost answer succeeds even
     at 60. Storage ran the guard trigger first and could refuse that retry.
   - **JPEG** is checked by the declared type and by the bytes (`FF D8 FF`); Storage trusted the declared type. At most
     1,000,000 bytes (the bucket's `file_size_limit`): more answers `413 too_large`.
   - **A listing's photo** (sync and share) must also have its R2 object (`head`), because the row now exists before
     the object does.
   - **An admin may delete a shared photo** only while a removed public listing names it (spec section 3). The Postgres
     policy let admins delete any shared photo; the app never did more than this.
7. **Catalogue reads need a session.** The spec puts every `/v1` route behind the app session. Supabase let a
   signed-out phone read the public views with the anon key. See "Open questions".
8. **Bodies.**
   - Lists answer `{"rows": [...]}`, as `/v1/sync` does; one gym answers `{"gym": … | null}`.
   - Function results that were bare JSON become objects: `{id}`, `{confirm_count}`, `{cleared}`, `{admin}`.
   - Field names are the views' and functions' column names, so the app's row decoders read them unchanged.
   - A pulled listing nests `equipment_items: {kind_id}`, as PostgREST embedded it, so `GymListingDTO` decodes unchanged.
9. **Error mapping** (Postgres → API):

   | Postgres | API |
   |---|---|
   | `P0001` named (`daily_limit`, `gym_full`, …) | 422 with that code |
   | `'unknown target'`, `'unknown listing'` | 422 `unknown_target`, `unknown_listing` |
   | `42501` with a session | 403 `not_allowed` |
   | `22023` / `22P02` (`invalid place`, `unknown kind`, `invalid loads`, `invalid action`, a bad uuid) | 400 `bad_request`, the same message |
   | `23514`, `23505` (CHECKs, `clean_text`, the photo index) | 422 `row_rejected` |
   | the cap triggers | 422 `too_many_gyms` / `too_many_listings` |
   | Storage refusals | 422 `photo_*`, 409 `duplicate`, 413 `too_large` |

   A private gym pushed as public answered 42501 (RLS). It now answers `422 row_rejected`, from the
   `gyms_private_has_owner` CHECK; both are a refused row.
10. **Order of refusals.** Text and kind checks run before the limits. Postgres checked text in CHECKs at the insert,
    after the limits, so a bad request at its limit now hears about its text first.
11. **Public photos** carry `ETag` and `Cache-Control`, and a matching `If-None-Match` answers 304.
    - There's no Cache API: it doesn't apply on `workers.dev`, which the spec keeps.
    - A removed listing's photo is served until moderation deletes it, as Supabase's public URLs were.
12. **Exercise photos.** The route belongs here. Its local filling does too:
    - `scripts/upload-photos.mjs --target worker` writes with `wrangler r2 object put --local` into
      `server/.wrangler/state`, the folder `wrangler dev` reads. It checks what is there through the Worker's own
      public route (`HEAD`).
    - **Checked by probe:** objects that `wrangler r2 object put --local --persist-to X` writes, binary via `--pipe`
      included, are served by a `wrangler dev --local --persist-to X` that is already running, with their ETag (the
      MD5) and metadata.
    - The app's `PHOTO_HOSTING=storage` switch to `<API_URL>/photos/exercises/…` is iOS work: the iOS part of this
      plan, because it needs plan 27's `API_URL`.
    - The remote R2 upload and dropping the Supabase target are plan 30.
13. **The drift test** moves to Vitest. It reads `DomainLimits.swift` and the migrations with Vite's `?raw` import
    (probe: works in workerd for files outside `server/`), with no `eval`. It checks:
    - Swift ↔ `src/shared/domain-limits.ts`, name by name,
    - the numbers in the D1 CHECKs and the cap triggers.
    The Deno test keeps checking the Supabase copy until plan 30.
14. **`unblock_all`** is one batch: `DELETE … RETURNING`, then a log insert gated on `changes() > 0`. Probe:
    `changes()` in a later statement of a D1 batch counts the previous statement's rows.
15. **Constants that were literals in SQL stay so:** the 3 reports that flag a target, and the 1 MB photo size.
    `DomainLimits` keeps only what Swift has.

## File map

| File | Responsibility |
|---|---|
| `server/wrangler.jsonc`, `server/src/env.ts` | The three R2 bindings |
| `server/migrations/0005_gyms_photos.sql` | Fold keys, the private caps (triggers), the report-count index |
| `server/src/shared/domain-limits.ts` | The server's copy of `DomainLimits` |
| `server/src/sync/sql.ts` | Column-list SQL shared by the generic sync and the workout save |
| `server/src/sync/entities.ts`, `table-sync.ts`, `routes.ts`, `workouts.ts` | Owner column, pull scope, insert-only columns, `prepare`, pull shape |
| `server/src/sync/gym-rows.ts` | The rules on private gyms and listings |
| `server/src/sync/columns.ts` | `text` refuses U+0000 and lone surrogates |
| `server/src/sync/time.ts` | `DAY_AGO_SQL` |
| `server/src/gyms/visibility.ts` | Read rules with the caller's parameter; the item rule |
| `server/src/gyms/text.ts`, `loads.ts` | `clean_text`, trimming, case folding; the loads shape |
| `server/src/gyms/refusals.ts` | The gym, photo and moderation error codes |
| `server/src/gyms/catalogue.ts`, `share.ts`, `routes.ts` | `/v1/gyms`, `/v1/items`, `/v1/listings` |
| `server/src/moderation/targets.ts`, `reports.ts`, `admin.ts`, `routes.ts` | `/v1/reports`, `/v1/blocks`, `/v1/admin` |
| `server/src/photos/objects.ts`, `store.ts`, `routes.ts` | Buckets and names; upload and delete; `/v1/photos` |
| `server/src/photos/public.ts` | `/photos/shared/*`, `/photos/exercises/*` |
| `server/src/http/input.ts` | Reading bodies and queries of these routes |
| `server/src/http/errors.ts` | The trigger codes; 503 |
| `server/src/index.ts` | Mounting the routes |
| `server/test/*.test.ts`, `gym-fixtures.ts`, `helpers.ts`, `samples.ts` | Tests and their helpers |
| `scripts/upload-photos.mjs`, `upload-photos.test.mjs` | `--target worker` |
| `scripts/server-up.sh` | The local state folder named explicitly |
| `docs/media/README.md`, `server/README.md` | How it runs |

## The routes

All `/v1` routes need `Authorization: Bearer <session>`. Ids are lowercase in answers.

| Route | Body | Answer |
|---|---|---|
| `GET /v1/sync/gyms`, `POST /v1/sync/gyms` | `{rows: [GymDTO]}` | `{rows}` / `{acks}` (plan 26's contract) |
| `GET /v1/sync/gym-listings`, `POST /v1/sync/gym-listings` | `{rows: [GymListingDTO]}` | `{rows}` with `equipment_items: {kind_id}` / `{acks}` |
| `GET /v1/gyms/public?place=` | | `{gym: {id, name, address, latitude, longitude, maps_place_id, status, created_at, updated_at, is_mine} \| null}` |
| `GET /v1/gyms/:id/listings?offset=&limit=` | | `{rows: [{id, gym_id, item_id, kind_id, brand, model, photo_path, loads, quantity, notes, status, confirm_count, created_at, updated_at, is_mine, confirmed_by_me, item_is_mine}]}` |
| `GET /v1/items?kind=` | | `{rows: [{id, kind_id, brand, model, photo_path, photo_listing_id, status, created_at, updated_at, is_mine, gym_count}]}` |
| `POST /v1/gyms/find-or-create` | `{maps_place_id, name, address, latitude, longitude}` | `{id}` |
| `POST /v1/listings/share` | `{listing_id, gym_id, kind_id, brand, model, loads, quantity, notes, photo_path, force_new}` | `{status: "created", listing_id}` or `{status: "duplicates", listings: [{id, kind_id, brand, model, photo_path, loads, quantity, confirm_count}]}` |
| `POST /v1/listings/:id/confirm` | | `{confirm_count}` |
| `POST /v1/reports` | `{target_type, target_id, reason, note}` | `{status: "reported" \| "own" \| "already"}` |
| `POST /v1/blocks` | `{target_type, target_id}` | 204 |
| `DELETE /v1/blocks` | | `{cleared}` |
| `GET /v1/admin/me` | | `{admin}` |
| `GET /v1/admin/queue` | | `{rows: [{target_type, target_id, title, photo_path, report_count, reasons, notes, status, address, listing_notes}]}` |
| `POST /v1/admin/moderate` | `{target_type, target_id, action}` | `{status, photo_path}` |
| `POST /v1/admin/photo-deleted` | `{path}` | 204 |
| `PUT /v1/photos/private/:name`, `PUT /v1/photos/shared/:name` | JPEG bytes, `Content-Type: image/jpeg` | `{name}`; 409 `duplicate` |
| `GET /v1/photos/private/:name` | | the JPEG, `Cache-Control: private, no-store` |
| `DELETE /v1/photos/private/:name`, `DELETE /v1/photos/shared/:name` | | 204, also when nothing was there |
| `GET /v1/photos/mine` | | `{rows: [{bucket_id, name}]}` |
| `POST /v1/photos/detach` | | 204 |
| `GET /photos/shared/:name`, `GET /photos/exercises/:name` (no session) | | the photo or `manifest.json`, with `ETag`; 304 on `If-None-Match` |

## How to run things

As plan 26:

```bash
cd server
npx vitest run                  # every server test; one file: npx vitest run test/photos.test.ts
npx tsc --noEmit                # typecheck
cd .. && scripts/server-up.sh   # local Worker on http://127.0.0.1:8787 (needs server/.dev.vars)
node --test scripts/upload-photos.test.mjs
```

Expected output ends with `Test Files  N passed (N)` and `Tests  M passed (M)`; each task gives N and M. Plan 26
ended at `Test Files  11 passed (11)`, `Tests  160 passed (160)`. Ignore the `punycode` DEP0040 warning.

Review steps use the repo's agents: **code-reviewer** (spec compliance first, then quality), **security-reviewer**
where a task says so, and **typescript-reviewer**. Fix CRITICAL and HIGH findings in the task, with a test, before
moving on, and record them in the task as plan 26 did ("added after review").

---

### Task 1: R2 buckets and the server's limits

Three R2 bindings, the server's own copy of `DomainLimits`, and the drift test in Vitest.

**Files:**
- Modify: `server/wrangler.jsonc`, `server/src/env.ts`
- Create: `server/src/shared/domain-limits.ts`
- Test: `server/test/domain-limits-drift.test.ts`, `server/test/r2.test.ts`

- [ ] **Step 1: Write the failing tests**

`server/test/r2.test.ts`:

```ts
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'

// The three buckets of wrangler.jsonc, as local R2 in workerd (the same simulator `wrangler dev --local` uses).
describe('R2 buckets', () => {
  it('are three separate buckets', async () => {
    const name = `${crypto.randomUUID()}.jpg`
    await env.GYM_PHOTOS.put(name, new Uint8Array([0xff, 0xd8, 0xff]))
    expect(await env.GYM_PHOTOS.head(name)).not.toBeNull()
    expect(await env.GYM_PHOTOS_PRIVATE.head(name)).toBeNull()
    expect(await env.EXERCISE_PHOTOS.head(name)).toBeNull()
    await env.GYM_PHOTOS.delete(name)
    expect(await env.GYM_PHOTOS.head(name)).toBeNull()
  })

  it('give the MD5 as the ETag, and a conditional get without a body', async () => {
    const name = `${crypto.randomUUID()}.jpg`
    const stored = await env.GYM_PHOTOS.put(name, new TextEncoder().encode('hello'))
    expect(stored!.etag).toBe('5d41402abc4b2a76b9719d911017c592')
    const unchanged = await env.GYM_PHOTOS.get(name, { onlyIf: new Headers({ 'if-none-match': stored!.httpEtag }) })
    expect(unchanged).not.toBeNull()
    expect('body' in unchanged!).toBe(false)
  })
})
```

`server/test/domain-limits-drift.test.ts`:

```ts
import { describe, expect, it } from 'vitest'
import swiftSource from '../../ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift?raw'
import appSchema from '../migrations/0002_app_schema.sql?raw'
import { DomainLimits } from '../src/shared/domain-limits.ts'

// Fails when the server's limits drift from the Swift source of truth, or from the D1 CHECKs that enforce them. The
// Swift file is read as text: `public static let name = 40` and `public static let name: ClosedRange<T> = lo...hi`.
// The Deno test beside supabase/functions/_shared checks the Supabase copy until plan 30.

type Limit = number | { readonly min: number; readonly max: number }

function swiftNumber(raw: string): number {
  if (!/^-?[\d_]+(\.[\d_]+)?$/.test(raw)) throw new Error(`not a Swift number literal: '${raw}'`)
  return Number(raw.replace(/_/g, ''))
}

function swiftLimits(source: string): Record<string, Limit> {
  const out: Record<string, Limit> = {}
  for (const [, name, rhs] of source.matchAll(/public static let (\w+)(?::\s*ClosedRange<\w+>)?\s*=\s*(.+)$/gm)) {
    const value = rhs.replace(/\/\/.*$/, '').trim()
    const range = /^(-?[\d_.]+?)\.\.\.(-?[\d_.]+)$/.exec(value)
    if (range) out[name] = { min: swiftNumber(range[1]), max: swiftNumber(range[2]) }
    else if (/^-?[\d_.]+$/.test(value)) out[name] = swiftNumber(value)
  }
  return out
}

const swift = swiftLimits(swiftSource)
const L = DomainLimits
const between = (column: string, range: { readonly min: number; readonly max: number }) =>
  `${column} BETWEEN ${range.min} AND ${range.max}`

/** The CHECK text in 0002_app_schema.sql that enforces each limit. */
const SCHEMA_CHECKS = [
  `length(name) BETWEEN 1 AND ${L.routineNameMax}`, `json_array_length(exercises) <= ${L.routineExercisesMax}`,
  `length(n) BETWEEN 1 AND ${L.customExerciseNameMax}`, `length(name) BETWEEN 1 AND ${L.workoutNameMax}`,
  between('w_kg', L.setWeightKg), between('r', L.setReps), between('sec', L.setSeconds), between('min', L.setMinutes),
  between('dist_m', L.setDistanceM), between('w_kg', L.bodyweightKg), between('bf_pct', L.bodyFatPct),
  between('rest_sec', L.restSec), between('warmup_rest_sec', L.restSec), between('height_cm', L.heightCm),
  between('goal_weight_kg', L.goalWeightKg), between('training_days', L.trainingDays),
  `length(limits) <= ${L.limitsTextMax}`, between('deload_pct', L.deloadPct), between('birth_year', L.birthYear),
  between('min_sets', L.weeklySetTarget), between('max_sets', L.weeklySetTarget),
  `length(name) BETWEEN 1 AND ${L.gymNameMax}`, `length(address) <= ${L.gymAddressMax}`,
  between('quantity', L.listingQuantity), `length(notes) <= ${L.listingNotesMax}`,
  `length(brand) BETWEEN 1 AND ${L.itemBrandMax}`, `length(model) BETWEEN 1 AND ${L.itemModelMax}`,
  `length(private_brand) BETWEEN 1 AND ${L.itemBrandMax}`, `length(private_model) BETWEEN 1 AND ${L.itemModelMax}`,
  `length(note) <= ${L.reportNoteMax}`,
]

describe('domain limits', () => {
  it('finds the Swift constants (a parser that matched nothing would pass everything)', () => {
    expect(Object.keys(swift).length).toBeGreaterThanOrEqual(40)
  })

  it('has every Swift limit in the server, with the same value, and no others', () => {
    expect(DomainLimits).toEqual(swift)
  })

  it("keeps the D1 schema's CHECKs at the same numbers", () => {
    for (const check of SCHEMA_CHECKS) expect(appSchema, check).toContain(check)
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/r2.test.ts test/domain-limits-drift.test.ts`
Expected: FAIL. `env.GYM_PHOTOS` is undefined, and `../src/shared/domain-limits.ts` doesn't exist.

- [ ] **Step 3: Add the buckets**

In `server/wrangler.jsonc`, replace the first comment line's `(R2 comes in plan 28)` with `and three R2 buckets`, and
add after the `d1_databases` block:

```jsonc
  "r2_buckets": [
    // Shared listing photos: anyone reads them through the Worker (/photos/shared/<name>).
    { "binding": "GYM_PHOTOS", "bucket_name": "gym-photos" },
    // Private listing photos: their owner only, through /v1/photos/private/<name>.
    { "binding": "GYM_PHOTOS_PRIVATE", "bucket_name": "gym-photos-private" },
    // GymRollins' own exercise and kind photos and manifest.json: anyone reads them (/photos/exercises/<name>).
    { "binding": "EXERCISE_PHOTOS", "bucket_name": "exercise-photos" }
  ],
```

In `server/src/env.ts`, add after `DB: D1Database`:

```ts
  /** gym-photos: shared listing photos, read by anyone through /photos/shared. */
  GYM_PHOTOS: R2Bucket
  /** gym-photos-private: private listing photos, their owner only. */
  GYM_PHOTOS_PRIVATE: R2Bucket
  /** exercise-photos: GymRollins' own photos and manifest.json, read by anyone through /photos/exercises. */
  EXERCISE_PHOTOS: R2Bucket
```

The vitest plugin reads `wrangler.jsonc`, so the tests get the three buckets with no change to `vitest.config.ts`.

- [ ] **Step 4: Write `server/src/shared/domain-limits.ts`**

```ts
// TypeScript port of ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift, for the server. It is a copy of
// supabase/functions/_shared/domain-limits.ts until plan 30 removes that one. test/domain-limits-drift.test.ts fails
// when it drifts from the Swift source. Keep in sync by hand: nothing here is generated.
//
// Value limits shared with the Swift app and the D1 CHECKs (migrations/0002_app_schema.sql). Anything saved must fit
// these, or the row would be rejected when it syncs.
export const DomainLimits = {
  // Routines
  routineNameMax: 40,
  routineExercisesMax: 20,
  // Custom exercises and workouts
  customExerciseNameMax: 80,
  workoutNameMax: 80,
  // Workout sets
  setWeightKg: { min: 0, max: 1_000 },
  setReps: { min: 0, max: 1_000 },
  setSeconds: { min: 0, max: 86_400 },
  setMinutes: { min: 0, max: 1_440 },
  setDistanceM: { min: 0, max: 1_000_000 },
  // Body
  bodyweightKg: { min: 30, max: 300 },
  bodyFatPct: { min: 3, max: 60 },
  // Profile
  restSec: { min: 0, max: 900 },
  heightCm: { min: 100, max: 250 },
  goalWeightKg: { min: 30, max: 300 },
  trainingDays: { min: 1, max: 7 },
  limitsTextMax: 500,
  deloadPct: { min: 0, max: 0.5 },
  // Optional, for strength levels only (profiles.birth_year)
  birthYear: { min: 1900, max: 2100 },
  // Weekly hard-set targets per muscle group (muscle_targets.min_sets / max_sets)
  weeklySetTarget: { min: 0, max: 50 },
  // Gyms and equipment
  gymNameMax: 120,
  gymAddressMax: 300,
  listingQuantity: { min: 1, max: 50 },
  listingNotesMax: 280,
  itemBrandMax: 60,
  itemModelMax: 80,
  listingStackKg: { min: 0.25, max: 1_000 },
  listingStepKg: { min: 0.25, max: 50 },
  listingFixedWeightsMax: 60,
  listingFixedKg: { min: 0.25, max: 500 },
  privateGymsMax: 100,
  privateListingsMax: 1_000,
  gymActiveListingsMax: 300,
  // Daily limits per user, over a rolling 24 hours (src/gyms, src/moderation, src/photos)
  dailyGymCreations: 10,
  dailyShares: 30,
  dailyConfirmations: 100,
  dailyPhotoUploads: 60,
  dailyReports: 20,
  dailyBlocks: 20,
  dailyUnblocks: 3,
  reportNoteMax: 280,
} as const
```

- [ ] **Step 5: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  13 passed (13)`, `Tests  165 passed (165)`, and no type errors. `tsc` knows `*?raw` from the
`vite/client` types already in `tsconfig.json`.

- [ ] **Step 6: Commit**

```bash
git add server/wrangler.jsonc server/src/env.ts server/src/shared server/test/r2.test.ts \
  server/test/domain-limits-drift.test.ts
git commit -m "feat(server): R2 buckets and the server's domain limits"
```

- [ ] **Step 7: Review**

Ask **code-reviewer**:
- spec section 3 (three buckets, their names and roles);
- the drift test fails when a Swift value changes (try `gymNameMax = 121` in a scratch copy, never committed).
Then **typescript-reviewer** for quality.

---

### Task 2: Shared SQL, the caller's parameter, and the entity extensions

No behaviour changes. Plan 26's outcome asked for three things before gyms join sync:
- `Entity` with a pull scope and an owner column,
- the visibility fragments taking the caller's parameter,
- one module for the column-list SQL.

This task does them, plus the item read rule that the catalogue needs (Task 5).

**Files:**
- Create: `server/src/sync/sql.ts`
- Modify: `server/src/sync/entities.ts`, `server/src/sync/table-sync.ts`, `server/src/sync/routes.ts`,
  `server/src/sync/workouts.ts`, `server/src/gyms/visibility.ts`, `server/src/sync/gym-links.ts`
- Test: `server/test/visibility.test.ts`

- [ ] **Step 1: Write the failing tests**

`server/test/visibility.test.ts`:

```ts
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { gymReadable, itemReadable } from '../src/gyms/visibility.ts'
import { block, insertGym, insertItem, insertListing, makeAdmin, setStatus } from './gym-fixtures.ts'
import { signUp } from './helpers.ts'

const db = env.DB

/** Whether the caller, bound as ?3 (gym-links.ts binds it as ?2), can read the row. */
async function readable(table: 'gyms' | 'equipment_items', alias: string, rule: string, id: string, me: string) {
  const row = await db.prepare(`SELECT 1 FROM ${table} ${alias} WHERE ${alias}.id = ?1 AND ?2 = 'unused' AND ${rule}`)
    .bind(id, 'unused', me).first()
  return row !== null
}
const canReadItem = (item: string, me: string) => readable('equipment_items', 'i', itemReadable('i', '?3'), item, me)

describe('the read rules', () => {
  it('read the caller from the parameter they are given', async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'private', owner: a.userId })
    expect(await readable('gyms', 'g', gymReadable('g', '?3'), gym, a.userId)).toBe(true)
    expect(await readable('gyms', 'g', gymReadable('g', '?3'), gym, b.userId)).toBe(false)
  })

  it('show a branded item to its creator, and to others once it has an active shared listing', async () => {
    const a = await signUp()
    const b = await signUp()
    const item = await insertItem({ brand: 'Acme', model: 'R1', createdBy: a.userId })
    expect(await canReadItem(item, a.userId)).toBe(true)
    expect(await canReadItem(item, b.userId)).toBe(false)
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    await insertListing({ gym, item, visibility: 'public', addedBy: a.userId })
    expect(await canReadItem(item, b.userId)).toBe(true)
  })

  it('hide an item whose only listing is flagged, or whose creator the caller blocked', async () => {
    const a = await signUp()
    const b = await signUp()
    const c = await signUp()
    const item = await insertItem({ brand: 'Acme', model: 'R2', createdBy: a.userId })
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const listing = await insertListing({ gym, item, visibility: 'public', addedBy: a.userId })
    await block(b.userId, a.userId)
    expect(await canReadItem(item, b.userId)).toBe(false)
    expect(await canReadItem(item, c.userId)).toBe(true)
    await setStatus('gym_equipment', listing, 'flagged')
    expect(await canReadItem(item, c.userId)).toBe(false)
  })

  it('show a removed item only to an admin and its creator', async () => {
    const a = await signUp()
    const b = await signUp()
    const admin = await signUp()
    await makeAdmin(admin.userId)
    const item = await insertItem({ brand: 'Acme', model: 'R3', createdBy: a.userId })
    await setStatus('equipment_items', item, 'removed')
    expect(await canReadItem(item, admin.userId)).toBe(true)
    expect(await canReadItem(item, a.userId)).toBe(true)
    expect(await canReadItem(item, b.userId)).toBe(false)
  })

  it("don't count a listing by an author the caller blocked towards an item being shown", async () => {
    const creator = await signUp()
    const author = await signUp()
    const viewer = await signUp()
    const item = await insertItem({ brand: 'Acme', model: 'R4', createdBy: creator.userId })
    const gym = await insertGym({ visibility: 'public', createdBy: author.userId })
    await insertListing({ gym, item, visibility: 'public', addedBy: author.userId })
    expect(await canReadItem(item, viewer.userId)).toBe(true)
    await block(viewer.userId, author.userId)
    expect(await canReadItem(item, viewer.userId)).toBe(false)
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/visibility.test.ts`
Expected: FAIL, because `itemReadable` isn't exported and `gymReadable` takes one argument (`tsc` also fails).

- [ ] **Step 3: Write `server/src/sync/sql.ts`**

```ts
import type { Column } from './columns.ts'

// SQL text built from column lists, shared by the generic table sync (table-sync.ts) and the workout save
// (workouts.ts).

/** `a, b, c`: the columns' names. */
export const columnNames = (columns: readonly Column[]) => columns.map((c) => c.name).join(', ')

/** `json_extract(value, '$.a'), …`: each column read from one element of json_each(?). */
export const extracted = (columns: readonly Column[]) =>
  columns.map((c) => `json_extract(value, '$.${c.name}')`).join(', ')

/** `<column> IN (SELECT value FROM json_each(<param>))`: a list bound as one JSON value, within D1's 100 bound values. */
export const inJson = (column: string, param: string) => `${column} IN (SELECT value FROM json_each(${param}))`
```

- [ ] **Step 4: Extend `Entity`**

In `server/src/sync/entities.ts`:

1. Replace the imports with:

```ts
import type { Env } from '../env.ts'
import { ApiError } from '../http/errors.ts'
import { type Column, type Kind, RowError } from './columns.ts'
```

2. Replace the whole `Entity` interface with:

```ts
/** What a push's cross-row checks may read: the bindings (D1, the photo buckets) and the caller. */
export interface PushContext {
  readonly env: Env
  readonly userId: string
}

/** One synced table, which the app's SyncTransport pushes and pulls at /v1/sync/<name> (the names below). */
export interface Entity {
  readonly table: string
  /** The column that holds the caller's id: user_id (the default), or owner_id on gyms and listings. */
  readonly owner?: string
  /** A condition on the rows a pull answers, besides the owner: gyms and listings pull private rows only. */
  readonly scope?: string
  /** The ON CONFLICT target: the owner plus the row's key, or a row id alone (then other accounts' ids are refused). */
  readonly conflict: readonly string[]
  /** The column whose value is the ack id. The app matches acks lowercased. */
  readonly ackKey: string
  /** KeysetPager's tiebreak after updated_at, and how `after` is read. */
  readonly tiebreak: { readonly column: string; readonly kind: 'text' | 'int' }
  /** What the app sends and gets back, besides updated_at (and user_id, on the profile). */
  readonly columns: readonly Column[]
  /** Columns written on insert only, as SQL expressions in which ?2 is the caller (an author, created_at). */
  readonly insertOnly?: Readonly<Record<string, string>>
  /** When an update applies, besides the owner check. Default: last write wins by the device's edit time. */
  readonly applies?: string
  /** Update expressions in place of `excluded.<column>`. */
  readonly onUpdate?: Readonly<Record<string, string>>
  /** Pulled rows carry user_id: the profile's tiebreak. */
  readonly pullsUserId?: boolean
  /** More expressions a pull selects (`expr AS name`), and the pulled row as the app decodes it. */
  readonly pull?: {
    readonly select: readonly string[]
    readonly shape: (row: Record<string, unknown>) => Record<string, unknown>
  }
  /** Rules on one stored row before anything is written (text, JSON shape); answers the row to store. */
  readonly prepare?: (row: Record<string, unknown>, label: string) => Record<string, unknown>
  /** Checks that span rows or tables, before anything is written. */
  readonly check?: (ctx: PushContext, rows: readonly Record<string, unknown>[]) => Promise<void>
}

/** The column that holds the caller's id. */
export const ownerOf = (entity: Entity) => entity.owner ?? 'user_id'
```

3. Change `ownRoutines` to take the context:

```ts
/** A day's routine must be the caller's (Postgres: the foreign key plus RLS's with check). Tombstones count. */
async function ownRoutines(ctx: PushContext, rows: readonly Record<string, unknown>[]) {
  const ids = [...new Set(rows.flatMap((r) => (typeof r.routine_id === 'string' ? [r.routine_id] : [])))]
  if (ids.length === 0) return
  const { results } = await ctx.env.DB.prepare(
    'SELECT id FROM routines WHERE user_id = ?1 AND id IN (SELECT value FROM json_each(?2))',
  ).bind(ctx.userId, JSON.stringify(ids)).all<{ id: string }>()
  const mine = new Set(results.map((r) => r.id))
  const missing = ids.find((id) => !mine.has(id))
  if (missing !== undefined) throw new RowError(`routine_id ${missing} is not one of your routines`)
}
```

- [ ] **Step 5: Rewrite `server/src/sync/table-sync.ts`**

```ts
import type { Env } from '../env.ts'
import { ApiError } from '../http/errors.ts'
import { storedRow, wireRow } from './columns.ts'
import { type Entity, ownerOf } from './entities.ts'
import { columnNames, extracted } from './sql.ts'
import { laterStamp, normalizeTimestamp, NOW_SQL } from './time.ts'

export interface Ack {
  readonly id: string
  readonly updated_at: string
}

export interface PullQuery {
  readonly since: string | null
  readonly after: string | number | null
  readonly limit: number
}

/** The app pushes at most 200 rows at a time; this leaves room. */
export const MAX_PUSH_ROWS = 500
export const DEFAULT_PULL_LIMIT = 500
export const MAX_PULL_LIMIT = 1000

const bad = (message: string) => new ApiError(400, 'bad_request', message)

/**
 * The keyset condition for a pull, with since as ?2 and after as ?3: rows changed after `since`, or at `since` with a
 * tiebreak after `after` (KeysetPager's next page). No since: every row.
 */
export const afterSql = (tiebreak: string) =>
  `(?2 IS NULL OR updated_at > ?2 OR (?3 IS NOT NULL AND updated_at = ?2 AND ${tiebreak} > ?3))`

/**
 * Stores a push in one statement. A row whose edit is older than the stored one (or that another account holds) is
 * skipped and gets no ack, as Postgres's lww_guard skipped it; the app keeps it dirty and the next pull overwrites it.
 */
export async function pushRows(env: Env, userId: string, entity: Entity, body: unknown): Promise<Ack[]> {
  const raw = (body as { rows?: unknown } | null)?.rows
  if (!Array.isArray(raw)) throw bad('Expected {"rows": [...]}.')
  if (raw.length > MAX_PUSH_ROWS) throw bad(`At most ${MAX_PUSH_ROWS} rows per push.`)
  const rows = raw.map((row, index) => {
    const label = `rows[${index}]`
    const stored = storedRow(entity.columns, row, label)
    return entity.prepare ? entity.prepare(stored, label) : stored
  })
  if (rows.length === 0) return []
  const json = JSON.stringify(rows)
  if (!entity.conflict.includes(ownerOf(entity))) await refuseOthersRows(env.DB, userId, entity, json)
  await entity.check?.({ env, userId }, rows)
  const { results } = await env.DB.prepare(upsertSql(entity)).bind(json, userId)
    .all<{ id: string | number; updated_at: string }>()
  return results.map((r) => ({ id: String(r.id), updated_at: r.updated_at }))
}

/**
 * A row id another account holds is refused outright, as Postgres's RLS refused it (42501). `IS NOT`, because a
 * public gym or listing has no owner.
 */
async function refuseOthersRows(db: D1Database, userId: string, entity: Entity, json: string) {
  const key = entity.conflict[0]
  const other = await db.prepare(
    `SELECT 1 FROM ${entity.table} WHERE ${key} IN (SELECT json_extract(value, '$.${key}') FROM json_each(?1)) ` +
      `AND ${ownerOf(entity)} IS NOT ?2 LIMIT 1`,
  ).bind(json, userId).first()
  if (other) throw new ApiError(403, 'not_allowed', 'That row belongs to another account.')
}

export function upsertSql(entity: Entity): string {
  const owner = ownerOf(entity)
  const names = entity.columns.map((c) => c.name)
  const insertOnly = Object.entries(entity.insertOnly ?? {})
  const updates = names.filter((n) => !entity.conflict.includes(n))
    .map((n) => `${n} = ${entity.onUpdate?.[n] ?? `excluded.${n}`}`)
  const applies = entity.applies ?? `excluded.client_updated_at >= ${entity.table}.client_updated_at`
  const stampSql = `updated_at = ${laterStamp(`${entity.table}.updated_at`, 'excluded.updated_at')}`
  const into = [owner, ...names, ...insertOnly.map(([name]) => name), 'updated_at']
  const values = ['?2', extracted(entity.columns), ...insertOnly.map(([, sql]) => sql), NOW_SQL]
  return `INSERT INTO ${entity.table} (${into.join(', ')})
SELECT ${values.join(', ')} FROM json_each(?1) WHERE true
ON CONFLICT (${entity.conflict.join(', ')}) DO UPDATE SET ${[...updates, stampSql].join(', ')}
WHERE ${entity.table}.${owner} = excluded.${owner} AND (${applies})
RETURNING ${entity.ackKey} AS id, updated_at`
}

/** One page of the caller's rows, oldest change first, tombstones included. */
export async function pullRows(db: D1Database, userId: string, entity: Entity, query: PullQuery) {
  const select = [
    ...(entity.pullsUserId ? ['user_id'] : []), columnNames(entity.columns), 'updated_at', ...(entity.pull?.select ?? []),
  ]
  const where = [`${ownerOf(entity)} = ?1`, ...(entity.scope ? [entity.scope] : []), afterSql(entity.tiebreak.column)]
  const { results } = await db.prepare(
    `SELECT ${select.join(', ')} FROM ${entity.table} WHERE ${where.join(' AND ')} ` +
      `ORDER BY updated_at, ${entity.tiebreak.column} LIMIT ?4`,
  ).bind(userId, query.since, query.after, query.limit).all<Record<string, unknown>>()
  return results.map((row) => {
    const wired = wireRow(entity.columns, row)
    return entity.pull ? entity.pull.shape(wired) : wired
  })
}

/** `?since=<timestamp>&after=<tiebreak>&limit=<n>`. The limit is never cut silently: the app stops at a short page. */
export function parsePullQuery(query: Record<string, string | undefined>, tiebreak: 'text' | 'int'): PullQuery {
  const since = query.since === undefined ? null : normalizeTimestamp(query.since)
  if (query.since !== undefined && since === null) throw bad('since must be a timestamp.')
  let after: string | number | null = null
  if (query.after !== undefined) {
    if (since === null) throw bad('after needs since.')
    if (query.after === '') throw bad('after must not be empty.')
    if (tiebreak === 'int' && !/^\d+$/.test(query.after)) throw bad('after must be a whole number.')
    after = tiebreak === 'int' ? Number(query.after) : query.after
  }
  const limit = query.limit === undefined ? DEFAULT_PULL_LIMIT : Number(query.limit)
  if (!Number.isInteger(limit) || limit < 1 || limit > MAX_PULL_LIMIT) throw bad(`limit must be 1 to ${MAX_PULL_LIMIT}.`)
  return { since, after, limit }
}
```

`refuseOthersRows` now runs before `check`. Only `weekdays` has a check today, and its conflict target includes
`user_id`, so its order doesn't change.

- [ ] **Step 6: Pass the bindings from the route, and share the SQL with the workout save**

In `server/src/sync/routes.ts`, change the push route's call to:

```ts
  const acks = await pushRows(c.env, c.var.userId, entityNamed(c.req.param('entity')), await jsonBody(c))
```

In `server/src/sync/workouts.ts`, delete these two lines:

```ts
const names = (columns: readonly Column[]) => columns.map((c) => c.name).join(', ')
const extracted = (columns: readonly Column[]) => columns.map((c) => `json_extract(value, '$.${c.name}')`).join(', ')
```

and add to the imports:

```ts
import { columnNames as names, extracted } from './sql.ts'
```

- [ ] **Step 7: Rewrite `server/src/gyms/visibility.ts`**

```ts
// Who may read a gym, an item or a listing, and when a workout's link to one survives: the Postgres read policies and
// gym_link_survives / listing_link_survives (supabase/migrations/20261030000001_gyms.sql), for the app's own session.
// Plan 29 adds Claude's side (the mcp_read_gyms toggle). Each fragment takes `me`, the SQL parameter that holds the
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
```

In `server/src/sync/gym-links.ts`, pass the caller's parameter, which `idsWhere` binds as `?2`, at the four call sites:
`gymLinkSurvives('g', '?2')`, `gymReadable('g', '?2')`, `listingLinkSurvives('e', '?2')`, `listingReadable('e', '?2')`.

- [ ] **Step 8: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  14 passed (14)`, `Tests  170 passed (170)`. Plan 26's 160 tests pass unchanged, which is the
check that nothing moved.

- [ ] **Step 9: Commit**

```bash
git add server/src/sync server/src/gyms/visibility.ts server/test/visibility.test.ts
git commit -m "refactor(server): owner column, pull scope and caller parameter for gym sync"
```

- [ ] **Step 10: Review**

Ask **code-reviewer** to diff `upsertSql(ENTITIES.<each plan-26 entity>)` before and after: the text must be the same
for all seven tables. Then **typescript-reviewer**.

---

### Task 3: Text rules, loads and case folding

Pure functions with unit tests: `clean_text`, `btrim`, the catalogue's case folding, and `valid_loads`. The `text`
column kind also starts refusing U+0000 and lone surrogates (decision 4).

**Files:**
- Create: `server/src/gyms/text.ts`, `server/src/gyms/loads.ts`
- Modify: `server/src/sync/columns.ts`
- Test: `server/test/text.test.ts`, `server/test/loads.test.ts`, `server/test/columns.test.ts`

- [ ] **Step 1: Write the failing tests**

`server/test/text.test.ts` (the cases of `gym_rules.test.sql` lines 117–180, and both ends of every range):

```ts
import { describe, expect, it } from 'vitest'
import { foldKey, isCleanText, trimmedOrNull, trimSpaces } from '../src/gyms/text.ts'

const at = (codePoint: number) => `Gym${String.fromCodePoint(codePoint)}One`

describe('clean text', () => {
  it('refuses control characters, and in text with lines allows only line breaks', () => {
    expect(isCleanText('Iron Works')).toBe(true)
    expect(isCleanText('by the door\nleft side')).toBe(false)
    expect(isCleanText('by the door\nleft side', true)).toBe(true)
    expect(isCleanText('two\r\nlines', true)).toBe(true)
    expect(isCleanText('a\tb', true)).toBe(false)
    expect(isCleanText('a\u0000b', true)).toBe(false)
    expect(isCleanText('a\u001Fb', true)).toBe(false)
  })

  it('refuses each hidden range at both ends, and takes its neighbours', () => {
    const hidden = [
      0x7f, 0x9f, 0xad, 0x34f, 0x61c, 0x115f, 0x1160, 0x17b4, 0x17b5, 0x180b, 0x180e, 0x180f, 0x200b, 0x200e, 0x200f,
      0x2028, 0x2029, 0x202e, 0x2060, 0x206f, 0x3164, 0xfe00, 0xfe0a, 0xfe0e, 0xfeff, 0xffa0, 0xfff9, 0xfffc, 0xe000,
      0xf8ff, 0x1d173, 0x1d17a, 0xe0000, 0xe0001, 0xe0080, 0xe01ef, 0xf0000, 0xffffd, 0x100000, 0x10fffd,
    ]
    const neighbours = [
      0xac, 0xae, 0x34e, 0x350, 0x115e, 0x1161, 0x17b3, 0x17b6, 0x180a, 0x1810, 0x2027, 0x202f, 0x3163, 0x3165, 0xfdff,
      0xfe10, 0xff9f, 0xffa1, 0xfffd, 0xd7ff, 0xf900, 0xeffff, 0xffffe, 0x1d172, 0x1d17b, 0xe01f0, 0x1f4aa,
    ]
    for (const cp of hidden) expect(isCleanText(at(cp)), cp.toString(16)).toBe(false)
    for (const cp of neighbours) expect(isCleanText(at(cp)), cp.toString(16)).toBe(true)
  })

  it('keeps the zero width joiners next to non-ASCII text only', () => {
    expect(isCleanText('Iron\u200DGym')).toBe(false)
    expect(isCleanText('\u200DIron')).toBe(false)
    expect(isCleanText('Gym\u200D')).toBe(false)
    expect(isCleanText('Iron\u200CGym')).toBe(false)
    expect(isCleanText('👨\u200D👩')).toBe(true)
    expect(isCleanText('\u0645\u200C\u06CC')).toBe(true)
    expect(isCleanText('Iron Gym 💪 \u0915\u094D\u200D\u0937')).toBe(true)
    expect(isCleanText('Équinoxe Fitness – 24/7 (Nørre) 健身房 Спорт-зал')).toBe(true)
  })

  it('takes U+FE0F only after non-ASCII text', () => {
    expect(isCleanText('\u2764\uFE0F')).toBe(true)
    expect(isCleanText('a\uFE0Fb')).toBe(false)
    expect(isCleanText('\uFE0Fa')).toBe(false)
    expect(isCleanText('a\uFE0F')).toBe(false)
  })

  it('refuses the line separator even where text has lines, and half of a UTF-16 pair', () => {
    expect(isCleanText('a\u2028b', true)).toBe(false)
    expect(isCleanText('a\uD800b')).toBe(false)
    expect(isCleanText('a\uDC00')).toBe(false)
    expect(isCleanText('😀')).toBe(true)
  })
})

describe('trimming and folding', () => {
  it('trims spaces only, as btrim did, and turns empty text into null', () => {
    expect(trimSpaces('  1 Main St ')).toBe('1 Main St')
    expect(trimSpaces('\tx\n')).toBe('\tx\n')
    expect(trimmedOrNull('   ')).toBeNull()
    expect(trimmedOrNull(null)).toBeNull()
    expect(trimmedOrNull(' a face ')).toBe('a face')
  })

  it('folds case in every script, where SQLite folds ASCII only', () => {
    expect(foldKey('Hammer Strength')).toBe('hammer strength')
    expect(foldKey('ÄRGER')).toBe('ärger')
    expect(foldKey('СПОРТ')).toBe('спорт')
    expect(foldKey(null)).toBeNull()
  })
})
```

`server/test/loads.test.ts` (the cases of `gyms.test.sql` lines 110–126):

```ts
import { describe, expect, it } from 'vitest'
import { parseLoads } from '../src/gyms/loads.ts'

describe('listing loads', () => {
  it('takes the four shapes and rebuilds them in one key order', () => {
    expect(parseLoads({ type: 'none' })).toEqual({ type: 'none' })
    expect(parseLoads({ type: 'plates' })).toEqual({ type: 'plates' })
    expect(JSON.stringify(parseLoads({ stepKg: 5, type: 'stack', maxKg: 100 })))
      .toBe('{"type":"stack","maxKg":100,"stepKg":5}')
    expect(parseLoads({ type: 'stack', maxKg: 113.4 })).toEqual({ type: 'stack', maxKg: 113.4 })
    expect(parseLoads({ type: 'stack', maxKg: 113.4, stepKg: null })).toEqual({ type: 'stack', maxKg: 113.4 })
    // The same double as the app sent, written in JavaScript's shortest form.
    expect(JSON.stringify(parseLoads({ kg: [24.040395609999998, 20], type: 'fixed' })))
      .toBe('{"type":"fixed","kg":[24.040395609999997,20]}')
  })

  it('refuses numbers outside the limits or unreadable, as valid_kg did', () => {
    expect(parseLoads({ type: 'stack', maxKg: -1 })).toBeNull()
    expect(parseLoads({ type: 'stack', maxKg: JSON.parse('1e-400') })).toBeNull()
    expect(parseLoads({ type: 'stack', maxKg: 1000.5 })).toBeNull()
    expect(parseLoads({ type: 'stack', maxKg: 1000, stepKg: 1000 })).toBeNull()
    expect(parseLoads({ type: 'stack', maxKg: 10, stepKg: 20 })).toBeNull()
    expect(parseLoads({ type: 'fixed', kg: ['x'] })).toBeNull()
    expect(parseLoads({ type: 'fixed', kg: [JSON.parse('1e-400')] })).toBeNull()
    expect(parseLoads({ type: 'fixed', kg: [] })).toBeNull()
    expect(parseLoads({ type: 'fixed', kg: [500.5] })).toBeNull()
    expect(parseLoads({ type: 'fixed', kg: Array.from({ length: 61 }, () => 20) })).toBeNull()
    expect(parseLoads({ type: 'fixed', kg: Array.from({ length: 60 }, () => 20) })).not.toBeNull()
  })

  it('refuses any other key, type or shape', () => {
    expect(parseLoads({ type: 'plates', html: '<script>' })).toBeNull()
    expect(parseLoads({ type: 'none', ['x'.repeat(3000)]: 1 })).toBeNull()
    expect(parseLoads({ type: 'stack', 'maxKg,type': 1 })).toBeNull()
    expect(parseLoads({ type: 'barbell' })).toBeNull()
    expect(parseLoads({ type: 1 })).toBeNull()
    expect(parseLoads([{ type: 'none' }])).toBeNull()
    expect(parseLoads(null)).toBeNull()
    expect(parseLoads('none')).toBeNull()
  })
})
```

In `server/test/columns.test.ts`, add inside `describe('storedValue', …)`:

```ts
  it('refuses text holding U+0000 or half of a UTF-16 pair, which D1 would store past its length CHECKs', () => {
    expect(stored(col('text'), 'Push day 💪')).toBe('Push day 💪')
    for (const raw of ['a\u0000b', 'a\uD800b', '\uDC00']) {
      expect(() => stored(col('text'), raw)).toThrow('rows[0].x is not a valid text')
    }
  })
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/text.test.ts test/loads.test.ts test/columns.test.ts`
Expected: FAIL. The two modules don't exist, and `stored(col('text'), 'a\u0000b')` returns the text.

- [ ] **Step 3: Refuse unstorable text in `server/src/sync/columns.ts`**

Add above `storedValue`:

```ts
/**
 * U+0000, which D1 stores but SQLite's length() stops at (so it slips past every length CHECK), and half of a UTF-16
 * pair, which D1 stores as invalid UTF-8. Postgres refused both.
 */
const UNSTORABLE = /\u0000|[\uD800-\uDFFF]/u

/** Text D1 stores as it was sent. */
export const isStorableText = (text: string) => !UNSTORABLE.test(text)
```

and change the `text` case of `convert` to:

```ts
    case 'text':
      return typeof raw === 'string' && isStorableText(raw) ? raw : undefined
```

- [ ] **Step 4: Write `server/src/gyms/text.ts`**

```ts
import { RowError } from '../sync/columns.ts'

// The text rules on shared gym data (gym_private.clean_text, supabase/migrations/20261030000001_gyms.sql), and the
// trimming and case folding the sharing functions did. D1's CHECKs keep only the control-character part: SQLite has no
// Unicode classes, and its lower() folds ASCII only.

/** Control characters. U+0000 is refused too: Postgres couldn't hold it, and D1's length() stops at it. */
const CONTROL = /[\u0000-\u001F]/
/** In text that has lines (notes), only \n and \r are allowed; a tab is not, as in clean_text(t, true). */
const CONTROL_IN_LINES = /[\u0000-\u0009\u000B\u000C\u000E-\u001F]/

/**
 * What the eye can't see but a model can read, code point for code point as clean_text lists it: C1 controls, the soft
 * hyphen, the combining grapheme joiner, the Arabic letter mark, the Hangul and Khmer fillers, the Mongolian variation
 * selectors, the zero width space, the direction marks, the line and paragraph separators and the bidi embeddings, the
 * word joiner and invisible operators, variation selectors 1–15, the BOM, the interlinear annotation marks, the object
 * replacement character, the private use areas, the musical formatting characters and the tag characters.
 */
const HIDDEN = new RegExp(
  '[\\u007F-\\u009F\\u00AD\\u034F\\u061C\\u115F\\u1160\\u17B4\\u17B5\\u180B-\\u180F\\u200B\\u200E\\u200F' +
    '\\u2028-\\u202E\\u2060-\\u206F\\u3164\\uFE00-\\uFE0E\\uFEFF\\uFFA0\\uFFF9-\\uFFFC\\uE000-\\uF8FF' +
    '\\u{1D173}-\\u{1D17A}\\u{E0000}-\\u{E01EF}\\u{F0000}-\\u{FFFFD}\\u{100000}-\\u{10FFFD}]',
  'u',
)

/**
 * U+200C and U+200D (the zero width joiners) are also emoji and script characters, so they stay next to non-ASCII text;
 * between ASCII letters or at an edge they can only hide something. U+FE0F stays only after the character it applies to.
 */
const LOOSE_JOINER = /(^|[\u0001-\u007F])[\u200C\u200D\uFE0F]|[\u200C\u200D]([\u0001-\u007F]|$)/u

/** Half of a UTF-16 pair. */
const LONE_SURROGATE = /[\uD800-\uDFFF]/u

/** clean_text(t, lines). */
export function isCleanText(text: string, lines = false): boolean {
  return !(lines ? CONTROL_IN_LINES : CONTROL).test(text) && !HIDDEN.test(text) && !LOOSE_JOINER.test(text) &&
    !LONE_SURROGATE.test(text)
}

/** Refuses shared text that breaks clean_text: 422 row_rejected, as the CHECK's 23514 was. */
export function requireCleanText(text: string | null, name: string, lines = false): void {
  if (text !== null && !isCleanText(text, lines)) throw new RowError(`${name} has hidden or control characters`)
}

/** btrim(t): spaces only, as Postgres's btrim with no characters given. */
export const trimSpaces = (text: string) => text.replace(/^ +| +$/g, '')

/** nullif(btrim(t), ''). */
export function trimmedOrNull(text: string | null | undefined): string | null {
  if (text === null || text === undefined) return null
  const trimmed = trimSpaces(text)
  return trimmed === '' ? null : trimmed
}

/** The catalogue's identity key for a brand or model (lower() as Postgres did it, for every script). */
export const foldKey = (text: string | null) => (text === null ? null : text.toLowerCase())
```

- [ ] **Step 5: Write `server/src/gyms/loads.ts`**

```ts
import { DomainLimits } from '../shared/domain-limits.ts'

// A listing's loads (gym_private.valid_loads and valid_kg, supabase/migrations/20261030000001_gyms.sql): exact keys and
// numbers within the limits, because every client decodes these rows and one unreadable row would break a whole gym.
// Stored as compact JSON rebuilt from the checked values, so what D1 holds is short and in one key order.

export type Loads =
  | { readonly type: 'none' | 'plates' }
  | { readonly type: 'stack'; readonly maxKg: number; readonly stepKg?: number }
  | { readonly type: 'fixed'; readonly kg: readonly number[] }

interface Range {
  readonly min: number
  readonly max: number
}

/** valid_kg: a number within the range, whose text is short enough for every client to decode. */
function isKg(value: unknown, range: Range): value is number {
  return typeof value === 'number' && Number.isFinite(value) && String(value).length <= 24 &&
    value >= range.min && value <= range.max
}

/** Exactly these keys, compared one by one (a key may itself hold a comma). */
function hasKeys(value: object, keys: readonly string[]): boolean {
  const actual = Object.keys(value).sort()
  const wanted = [...keys].sort()
  return actual.length === wanted.length && actual.every((key, i) => key === wanted[i])
}

/** The loads to store, or null for anything valid_loads refused. A null stepKg means none and is dropped. */
export function parseLoads(raw: unknown): Loads | null {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return null
  const loads = raw as Record<string, unknown>
  switch (loads.type) {
    case 'none':
    case 'plates':
      return hasKeys(loads, ['type']) ? { type: loads.type } : null
    case 'stack': {
      if (!hasKeys(loads, ['maxKg', 'type']) && !hasKeys(loads, ['maxKg', 'stepKg', 'type'])) return null
      const { maxKg, stepKg } = loads
      if (!isKg(maxKg, DomainLimits.listingStackKg)) return null
      if (stepKg === undefined || stepKg === null) return { type: 'stack', maxKg }
      if (!isKg(stepKg, DomainLimits.listingStepKg) || stepKg > maxKg) return null
      return { type: 'stack', maxKg, stepKg }
    }
    case 'fixed': {
      const { kg } = loads
      if (!hasKeys(loads, ['kg', 'type']) || !Array.isArray(kg)) return null
      if (kg.length < 1 || kg.length > DomainLimits.listingFixedWeightsMax) return null
      if (!kg.every((weight) => isKg(weight, DomainLimits.listingFixedKg))) return null
      return { type: 'fixed', kg: kg as number[] }
    }
    default:
      return null
  }
}
```

- [ ] **Step 6: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  16 passed (16)`, `Tests  181 passed (181)`.

- [ ] **Step 7: Commit**

```bash
git add server/src/gyms/text.ts server/src/gyms/loads.ts server/src/sync/columns.ts server/test/text.test.ts \
  server/test/loads.test.ts server/test/columns.test.ts
git commit -m "feat(server): clean_text, loads and case folding in TypeScript"
```

- [ ] **Step 8: Review**

Ask **code-reviewer** to compare `HIDDEN`, `CONTROL_IN_LINES` and `LOOSE_JOINER` with
`supabase/migrations/20261030000001_gyms.sql` lines 52–56 by code point. Print them with:
`python3 -c "import sys;[print(i+1,''.join(c if ord(c)<128 else '<U+%04X>'%ord(c) for c in l)) for i,l in enumerate(open(sys.argv[1]).read().split('\n')[51:56])]" supabase/migrations/20261030000001_gyms.sql`
Then **security-reviewer**: these rules keep invisible instructions out of text that reaches Claude.

---

### Task 4: Private gyms and listings in sync

`/v1/sync/gyms` and `/v1/sync/gym-listings`, with every rule the Postgres triggers and policies kept. The new
migration adds the caps and the fold keys.

**Files:**
- Create: `server/migrations/0005_gyms_photos.sql`, `server/src/sync/gym-rows.ts`, `server/src/gyms/refusals.ts`,
  `server/src/photos/objects.ts`
- Modify: `server/src/sync/entities.ts`, `server/src/http/errors.ts`, `server/test/gym-fixtures.ts`,
  `server/test/samples.ts`, `server/test/sync-rows.test.ts`, `server/test/domain-limits-drift.test.ts`
- Test: `server/test/sync-gyms.test.ts`

- [ ] **Step 1: Write the fixtures, the samples and the failing tests**

In `server/test/gym-fixtures.ts`:

1. Add to the imports:

```ts
import { foldKey } from '../src/gyms/text.ts'
```

2. Replace `insertItem` (0005 keeps a fold key beside every brand and model):

```ts
export async function insertItem(i: { brand: string; model: string; createdBy: string; kind?: string }): Promise<string> {
  const id = crypto.randomUUID()
  await env.DB.prepare(
    'INSERT INTO equipment_items (id, kind_id, brand, model, brand_key, model_key, created_by, created_at, updated_at) ' +
      'VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)',
  ).bind(id, i.kind ?? 'dumbbells', i.brand, i.model, foldKey(i.brand), foldKey(i.model), i.createdBy, T).run()
  return id
}
```

3. Add at the end:

```ts
/** The smallest bytes the server takes as a JPEG. */
export const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10])

/** A photo the account uploaded: its photo_objects row and, unless `stored` is false, its R2 object. */
export async function uploadedPhoto(
  owner: string,
  bucket: 'gym-photos' | 'gym-photos-private',
  options: { stored?: boolean } = {},
): Promise<string> {
  const name = await insertPhoto(owner, bucket)
  if (options.stored ?? true) {
    await (bucket === 'gym-photos' ? env.GYM_PHOTOS : env.GYM_PHOTOS_PRIVATE).put(name, JPEG)
  }
  return name
}
```

In `server/test/samples.ts`, add a `gyms` entry to each of `SAMPLES`, `BAD` and `KEY`:

```ts
  // SAMPLES: a private gym as GymDTO encodes it
  gyms: () => ({
    id: appUUID(), visibility: 'private', name: 'Home gym', address: '1 Main St', latitude: 52.37, longitude: 4.89,
    client_updated_at: T1, deleted_at: null,
  }),
```

```ts
  // BAD
  gyms: { latitude: 91 },
```

```ts
  // KEY
  gyms: (row) => String(row.id).toLowerCase(),
```

In `server/test/sync-rows.test.ts`, run the shared cases for every table with a sample. Listings need a gym first, so
they have their own file. Change

```ts
describe.each(Object.keys(ENTITIES))('%s', (entity) => {
```

to

```ts
describe.each(Object.keys(SAMPLES))('%s', (entity) => {
```

In `server/test/domain-limits-drift.test.ts`, add to the imports:

```ts
import capsMigration from '../migrations/0005_gyms_photos.sql?raw'
```

and add inside `describe('domain limits', …)`:

```ts
  it('keeps the cap triggers at the same numbers', () => {
    const caps = [[DomainLimits.privateGymsMax, 'too_many_gyms'], [DomainLimits.privateListingsMax, 'too_many_listings']]
    for (const [max, code] of caps) {
      const trigger = `id <> NEW.id) >= ${max}\nBEGIN\n  SELECT RAISE(ABORT, '${code}');`
      expect(capsMigration.split(trigger).length - 1, String(code)).toBe(2)
    }
  })
```

`server/test/sync-gyms.test.ts` (from `gyms.test.sql` lines 180–272 and `gym_rules.test.sql` lines 98–101):

```ts
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { genericItem, insertGym, insertItem, uploadedPhoto } from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'
import { appUUID, type Row, T1, T2 } from './samples.ts'

type Entity = 'gyms' | 'gym-listings'

const push = (token: string, entity: Entity, rows: unknown[]) =>
  request('POST', `/v1/sync/${entity}`, { token, body: { rows } })

async function pull(token: string, entity: Entity): Promise<Row[]> {
  const res = await request('GET', `/v1/sync/${entity}`, { token })
  expect(res.status).toBe(200)
  return (await res.json<{ rows: Row[] }>()).rows
}

async function refusal(res: Response, status = 422): Promise<{ code: string; message: string }> {
  expect(res.status).toBe(status)
  return (await res.json<{ error: { code: string; message: string } }>()).error
}

const count = async (sql: string, ...bindings: unknown[]) =>
  (await env.DB.prepare(sql).bind(...bindings).first<{ n: number }>())!.n

/** A private gym as GymDTO encodes it. */
const gymRow = (overrides: Row = {}): Row => ({
  id: appUUID(), visibility: 'private', name: 'Home', address: null, latitude: null, longitude: null,
  client_updated_at: T1, deleted_at: null, ...overrides,
})

/** A private listing as GymListingDTO encodes it: the kind's generic item, any brand and model on the listing. */
const listingRow = async (gymId: string, overrides: Row = {}): Promise<Row> => ({
  id: appUUID(), gym_id: gymId.toUpperCase(), item_id: (await genericItem('dumbbells')).toUpperCase(),
  visibility: 'private', photo_path: null, loads: { type: 'fixed', kg: [20, 24] }, quantity: 1, notes: null,
  private_brand: null, private_model: null, client_updated_at: T1, deleted_at: null, ...overrides,
})

/** An account with one private gym synced. */
async function withGym() {
  const account = await signUp()
  const gym = gymRow()
  expect((await push(account.token, 'gyms', [gym])).status).toBe(200)
  return { ...account, gymId: String(gym.id).toLowerCase() }
}

describe('private gyms', () => {
  it('are stored with the caller as owner and author, and a pull answers only their private gyms', async () => {
    const { token, userId } = await signUp()
    await insertGym({ visibility: 'public', createdBy: userId })
    const gym = gymRow()
    expect((await push(token, 'gyms', [gym])).status).toBe(200)
    const rows = await pull(token, 'gyms')
    expect(rows.map((r) => r.id)).toEqual([String(gym.id).toLowerCase()])
    const stored = await env.DB.prepare('SELECT owner_id, created_by, created_at, status FROM gyms WHERE id = ?1')
      .bind(String(gym.id).toLowerCase()).first<Row>()
    expect(stored).toMatchObject({ owner_id: userId, created_by: userId, status: 'active' })
    expect(stored!.created_at).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/)
  })

  it('refuse hidden characters, and a push that would make a gym public', async () => {
    const { token } = await signUp()
    expect(await refusal(await push(token, 'gyms', [gymRow({ name: 'Home\u200B' })]))).toEqual({
      code: 'row_rejected', message: 'rows[0].name has hidden or control characters',
    })
    expect((await refusal(await push(token, 'gyms', [gymRow({ visibility: 'public' })]))).code).toBe('row_rejected')
    expect(await pull(token, 'gyms')).toEqual([])
  })

  it('refuse an id that a public gym holds, and leave that gym alone', async () => {
    const { token, userId } = await signUp()
    const shared = await insertGym({ visibility: 'public', createdBy: userId })
    expect((await refusal(await push(token, 'gyms', [gymRow({ id: shared, client_updated_at: T2 })]), 403)).code)
      .toBe('not_allowed')
    expect(await count("SELECT count(*) AS n FROM gyms WHERE id = ?1 AND visibility = 'public' AND name = 'Test gym'",
      shared)).toBe(1)
  })

  it('hold 100 live gyms per account; the 101st is refused, an edit at the cap is not, and a deletion frees a slot',
    async () => {
      const { token } = await signUp()
      const gyms = Array.from({ length: 100 }, () => gymRow())
      expect((await push(token, 'gyms', gyms)).status).toBe(200)
      expect(await refusal(await push(token, 'gyms', [gymRow()]))).toEqual({
        code: 'too_many_gyms', message: "You've reached the limit of gyms on one account.",
      })
      expect((await push(token, 'gyms', [{ ...gyms[0], name: 'Renamed', client_updated_at: T2 }])).status).toBe(200)
      expect((await push(token, 'gyms', [{ ...gyms[1], deleted_at: T2, client_updated_at: T2 }])).status).toBe(200)
      expect((await push(token, 'gyms', [gymRow()])).status).toBe(200)
    })

  it("don't count tombstones, and refuse reviving past the cap without reviving any", async () => {
    const { token, userId } = await signUp()
    const live = Array.from({ length: 100 }, () => gymRow())
    const tombstones = Array.from({ length: 150 }, () => gymRow({ deleted_at: T1 }))
    expect((await push(token, 'gyms', live)).status).toBe(200)
    expect((await push(token, 'gyms', tombstones)).status).toBe(200)
    const revived = tombstones.slice(0, 3).map((g) => ({ ...g, deleted_at: null, client_updated_at: T2 }))
    expect((await refusal(await push(token, 'gyms', revived))).code).toBe('too_many_gyms')
    expect(await count('SELECT count(*) AS n FROM gyms WHERE owner_id = ?1 AND deleted_at IS NULL', userId)).toBe(100)
    const freed = live.slice(0, 3).map((g) => ({ ...g, deleted_at: T2, client_updated_at: T2 }))
    expect((await push(token, 'gyms', freed)).status).toBe(200)
    expect((await push(token, 'gyms', revived)).status).toBe(200)
  })
})

describe('private listings', () => {
  it('round-trip as GymListingDTO decodes them: the kind nested, loads parsed, brand and model on the listing',
    async () => {
      const { token, gymId } = await withGym()
      const row = await listingRow(gymId, { private_brand: 'Secret Brand', private_model: 'X', notes: 'by the door\nleft' })
      const res = await push(token, 'gym-listings', [row])
      expect(res.status).toBe(200)
      const [ack] = (await res.json<{ acks: { id: string; updated_at: string }[] }>()).acks
      expect(await pull(token, 'gym-listings')).toEqual([{
        ...row, id: String(row.id).toLowerCase(), gym_id: gymId, item_id: String(row.item_id).toLowerCase(),
        updated_at: ack.updated_at, equipment_items: { kind_id: 'dumbbells' },
      }])
      expect(await count("SELECT count(*) AS n FROM equipment_items WHERE brand = 'Secret Brand'")).toBe(0)
    })

  it('store loads compact, and refuse a shape the app could not read', async () => {
    const { token, gymId } = await withGym()
    const row = await listingRow(gymId, { loads: { kg: [20, 24], type: 'fixed' } })
    expect((await push(token, 'gym-listings', [row])).status).toBe(200)
    const stored = await env.DB.prepare('SELECT loads FROM gym_equipment WHERE id = ?1')
      .bind(String(row.id).toLowerCase()).first<{ loads: string }>()
    expect(stored!.loads).toBe('{"type":"fixed","kg":[20,24]}')
    const bad = await listingRow(gymId, { loads: { type: 'plates', html: '<script>' } })
    expect(await refusal(await push(token, 'gym-listings', [bad]))).toEqual({
      code: 'row_rejected', message: 'rows[0].loads is not a valid loads',
    })
  })

  it("refuse a gym that is missing or someone else's private gym with the same answer, and take a public gym",
    async () => {
      const a = await withGym()
      const b = await withGym()
      const missing = await refusal(await push(a.token, 'gym-listings', [await listingRow(crypto.randomUUID())]))
      const theirs = await refusal(await push(a.token, 'gym-listings', [await listingRow(b.gymId)]))
      expect(missing).toEqual({ code: 'row_rejected', message: 'rows[0].gym_id: unknown gym' })
      expect(theirs).toEqual(missing)
      const shared = await insertGym({ visibility: 'public', createdBy: b.userId })
      expect((await push(a.token, 'gym-listings', [await listingRow(shared)])).status).toBe(200)
    })

  it('refuse a branded catalogue item: brand and model stay on the listing', async () => {
    const { token, userId, gymId } = await withGym()
    const item = await insertItem({ brand: 'Acme', model: 'P1', createdBy: userId })
    expect(await refusal(await push(token, 'gym-listings', [await listingRow(gymId, { item_id: item })]))).toEqual({
      code: 'row_rejected', message: 'rows[0].item_id: a private listing uses a generic item',
    })
  })

  it("take the caller's own stored photo, and refuse a missing, unfinished or someone else's", async () => {
    const a = await withGym()
    const b = await signUp()
    const mine = await uploadedPhoto(a.userId, 'gym-photos-private')
    expect((await push(a.token, 'gym-listings', [await listingRow(a.gymId, { photo_path: mine })])).status).toBe(200)
    const theirs = await uploadedPhoto(b.userId, 'gym-photos-private')
    const unfinished = await uploadedPhoto(a.userId, 'gym-photos-private', { stored: false })
    const shared = await uploadedPhoto(a.userId, 'gym-photos')
    for (const photo of [theirs, unfinished, shared, `${crypto.randomUUID()}.jpg`]) {
      const res = await push(a.token, 'gym-listings', [await listingRow(a.gymId, { photo_path: photo })])
      expect(await refusal(res)).toEqual({ code: 'photo_missing', message: "That photo isn't uploaded." })
    }
  })

  it('check a photo only when it is new or changed', async () => {
    const { token, userId, gymId } = await withGym()
    const photo = await uploadedPhoto(userId, 'gym-photos-private')
    const row = await listingRow(gymId, { photo_path: photo })
    expect((await push(token, 'gym-listings', [row])).status).toBe(200)
    await env.GYM_PHOTOS_PRIVATE.delete(photo)
    await env.DB.prepare('DELETE FROM photo_objects WHERE name = ?1').bind(photo).run()
    expect((await push(token, 'gym-listings', [{ ...row, quantity: 2, client_updated_at: T2 }])).status).toBe(200)
  })

  it("refuse another account's listing id, and keep each account's listings to itself", async () => {
    const a = await withGym()
    const b = await withGym()
    const row = await listingRow(a.gymId)
    expect((await push(a.token, 'gym-listings', [row])).status).toBe(200)
    const hijack = await push(b.token, 'gym-listings', [{ ...row, gym_id: b.gymId, client_updated_at: T2 }])
    expect((await refusal(hijack, 403)).code).toBe('not_allowed')
    const tombstone = await push(b.token, 'gym-listings', [{ ...row, gym_id: b.gymId, deleted_at: T2, client_updated_at: T2 }])
    expect((await refusal(tombstone, 403)).code).toBe('not_allowed')
    expect(await pull(b.token, 'gym-listings')).toEqual([])
    expect((await pull(a.token, 'gym-listings'))[0]).toMatchObject({ client_updated_at: T1, deleted_at: null })
  })

  it('hold 1000 live listings per account; the 1001st is refused, and a deletion frees a slot', async () => {
    const { token, gymId } = await withGym()
    const base = await listingRow(gymId)
    const rows = Array.from({ length: 1000 }, () => ({ ...base, id: appUUID() }))
    expect((await push(token, 'gym-listings', rows.slice(0, 500))).status).toBe(200)
    expect((await push(token, 'gym-listings', rows.slice(500))).status).toBe(200)
    expect(await refusal(await push(token, 'gym-listings', [{ ...base, id: appUUID() }]))).toEqual({
      code: 'too_many_listings', message: "You've reached the limit of equipment on one account.",
    })
    expect((await push(token, 'gym-listings', [{ ...rows[0], deleted_at: T2, client_updated_at: T2 }])).status).toBe(200)
    expect((await push(token, 'gym-listings', [{ ...base, id: appUUID() }])).status).toBe(200)
  })

  it('refuse hidden characters in notes, brand and model, and a tab even in notes', async () => {
    const { token, gymId } = await withGym()
    for (const [column, value] of [['private_brand', 'Acme\u202E'], ['private_model', '\u{F0000}'], ['notes', 'a\tb']]) {
      const res = await push(token, 'gym-listings', [await listingRow(gymId, { [column]: value })])
      expect(await refusal(res)).toEqual({
        code: 'row_rejected', message: `rows[0].${column} has hidden or control characters`,
      })
    }
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/sync-gyms.test.ts test/sync-rows.test.ts test/domain-limits-drift.test.ts`
Expected: FAIL. `/v1/sync/gyms` answers `404 not_found`, the fixtures' `brand_key` column doesn't exist, and
`0005_gyms_photos.sql` can't be imported.

- [ ] **Step 3: Write `server/migrations/0005_gyms_photos.sql`**

```sql
-- Plan 28: gyms, photos and moderation on D1 (docs/plans/2026-11-08-plan-28-gyms-photos-moderation.md).

-- The catalogue's identity, case-folded in TypeScript (foldKey in server/src/gyms/text.ts): SQLite's lower() folds
-- ASCII only, so "Ä" and "ä" would otherwise be two items where Postgres had one. Every brand and model has its key.
ALTER TABLE equipment_items ADD COLUMN brand_key TEXT CHECK ((brand IS NULL) = (brand_key IS NULL));
ALTER TABLE equipment_items ADD COLUMN model_key TEXT CHECK ((model IS NULL) = (model_key IS NULL));
DROP INDEX equipment_items_identity;
CREATE UNIQUE INDEX equipment_items_identity
  ON equipment_items (kind_id, coalesce(brand_key, ''), coalesce(model_key, ''));

-- At most 100 live private gyms (DomainLimits.privateGymsMax) and 1000 live private listings (privateListingsMax) per
-- user: gym_private.check_private_gym_cap and check_private_listing_cap. Checked when a row becomes live: a new row (an
-- upsert's insert attempt, which SQLite runs before it finds the conflict, as Postgres did), or a tombstone cleared.
-- The row itself is left out of the count, so an upsert of a live row adds nothing. D1 runs one statement at a time,
-- and a trigger's count sees the rows its statement wrote before, so the cap holds without a lock. RAISE fails the whole
-- statement; the server answers 422 with the message as the code (server/src/http/errors.ts).
CREATE TRIGGER gyms_private_cap BEFORE INSERT ON gyms
  WHEN NEW.visibility = 'private' AND NEW.deleted_at IS NULL
    AND (SELECT count(*) FROM gyms WHERE owner_id = NEW.owner_id AND deleted_at IS NULL AND id <> NEW.id) >= 100
BEGIN
  SELECT RAISE(ABORT, 'too_many_gyms');
END;
CREATE TRIGGER gyms_private_cap_revived BEFORE UPDATE OF deleted_at ON gyms
  WHEN NEW.visibility = 'private' AND OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL
    AND (SELECT count(*) FROM gyms WHERE owner_id = NEW.owner_id AND deleted_at IS NULL AND id <> NEW.id) >= 100
BEGIN
  SELECT RAISE(ABORT, 'too_many_gyms');
END;
CREATE TRIGGER gym_equipment_private_cap BEFORE INSERT ON gym_equipment
  WHEN NEW.visibility = 'private' AND NEW.deleted_at IS NULL
    AND (SELECT count(*) FROM gym_equipment WHERE owner_id = NEW.owner_id AND deleted_at IS NULL AND id <> NEW.id) >= 1000
BEGIN
  SELECT RAISE(ABORT, 'too_many_listings');
END;
CREATE TRIGGER gym_equipment_private_cap_revived BEFORE UPDATE OF deleted_at ON gym_equipment
  WHEN NEW.visibility = 'private' AND OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL
    AND (SELECT count(*) FROM gym_equipment WHERE owner_id = NEW.owner_id AND deleted_at IS NULL AND id <> NEW.id) >= 1000
BEGIN
  SELECT RAISE(ABORT, 'too_many_listings');
END;

-- report_content's daily count (20 a day) reads a reporter's reports by time.
CREATE INDEX reports_reporter_created ON reports (reporter_id, created_at) WHERE reporter_id IS NOT NULL;
```

- [ ] **Step 4: Name the trigger refusals in `server/src/http/errors.ts`**

Add above `onError`:

```ts
/** What the migrations' triggers RAISE (0005_gyms_photos.sql), with the app's words for each. */
const RAISED: Readonly<Record<string, string>> = {
  too_many_gyms: "You've reached the limit of gyms on one account.",
  too_many_listings: "You've reached the limit of equipment on one account.",
}

/** The code a trigger raised, or null. D1 reports it as `D1_ERROR: <message>: SQLITE_CONSTRAINT (…)`. */
export function raisedCode(error: unknown): string | null {
  const message = error instanceof Error ? error.message : String(error)
  const match = /D1_ERROR: ([a-z_]+): SQLITE_CONSTRAINT/.exec(message)
  return match !== null && Object.hasOwn(RAISED, match[1]) ? match[1] : null
}
```

and in `onError`, before the `constraintMessage` line:

```ts
  const raised = raisedCode(error)
  if (raised !== null) return c.json(errorBody(raised, RAISED[raised]), 422)
```

- [ ] **Step 5: Write `server/src/gyms/refusals.ts`**

```ts
import { ApiError } from '../http/errors.ts'

// The refusals of the gym, photo and moderation routes (spec section 6). The codes keep the strings the Postgres
// functions and the bucket trigger raised, so the app's mappers and messages stay the same. The messages are the app's
// own words where it has them.
const refusal = (status: 403 | 409 | 422, code: string, message: string) => () => new ApiError(status, code, message)

export const Refusals = {
  dailyLimit: refusal(422, 'daily_limit', "You've shared a lot today. Try again tomorrow."),
  gymNotShareable: refusal(422, 'gym_not_shareable', "This gym can't take shared equipment."),
  gymFull: refusal(422, 'gym_full', 'This gym has as much shared equipment as it can hold.'),
  photoMissing: refusal(422, 'photo_missing', "That photo isn't uploaded."),
  photoInUse: refusal(422, 'photo_in_use', 'That photo already belongs to a listing.'),
  photoDailyLimit: refusal(422, 'photo_daily_limit', "You've uploaded a lot of photos today. Try again tomorrow."),
  photoNameInUse: refusal(422, 'photo_name_in_use', 'A listing already uses that photo name.'),
  photoBadName: refusal(422, 'photo_bad_name', 'A photo name is a lowercase UUID and .jpg.'),
  photoNotJpeg: refusal(422, 'photo_not_jpeg', 'Photos must be JPEG.'),
  photoOwnerMissing: refusal(422, 'photo_owner_missing', 'The account for this photo no longer exists.'),
  photoDuplicate: refusal(409, 'duplicate', 'A photo with that name is already uploaded.'),
  placeTaken: refusal(422, 'place_taken', 'Another gym now has this place.'),
  unknownTarget: refusal(422, 'unknown_target', 'unknown target'),
  unknownListing: refusal(422, 'unknown_listing', 'unknown listing'),
  notAllowed: refusal(403, 'not_allowed', 'Not allowed.'),
} as const
```

- [ ] **Step 6: Write `server/src/photos/objects.ts`**

```ts
import type { Env } from '../env.ts'
import { inJson } from '../sync/sql.ts'

// Gym photos live in R2; who owns each one lives in D1's photo_objects, as storage.objects.owner_id did. Names are bare
// random <uuid>.jpg: a folder per user in a public URL would give every reader that user's id.

export const SHARED_BUCKET = 'gym-photos'
export const PRIVATE_BUCKET = 'gym-photos-private'
export type GymBucket = typeof SHARED_BUCKET | typeof PRIVATE_BUCKET

/** guard_gym_photo's name rule: a lowercase UUID and .jpg. */
export const PHOTO_NAME = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$/

export const bucketOf = (env: Env, bucket: GymBucket): R2Bucket =>
  bucket === SHARED_BUCKET ? env.GYM_PHOTOS : env.GYM_PHOTOS_PRIVATE

/**
 * The names among `names` that the caller owns in `bucket` and whose object is stored. A row whose upload never wrote
 * its object (the Worker stopped in between) doesn't count: a listing can't point at a photo nobody can load.
 */
export async function ownedStoredPhotos(
  env: Env,
  userId: string,
  bucket: GymBucket,
  names: readonly string[],
): Promise<Set<string>> {
  const valid = names.filter((name) => PHOTO_NAME.test(name))
  if (valid.length === 0) return new Set()
  const { results } = await env.DB.prepare(
    `SELECT name FROM photo_objects WHERE bucket = ?1 AND owner_id = ?2 AND ${inJson('name', '?3')}`,
  ).bind(bucket, userId, JSON.stringify(valid)).all<{ name: string }>()
  const stored = await Promise.all(results.map(async ({ name }) =>
    (await bucketOf(env, bucket).head(name)) === null ? null : name))
  return new Set(stored.filter((name): name is string => name !== null))
}
```

- [ ] **Step 7: Write `server/src/sync/gym-rows.ts`**

```ts
import { parseLoads } from '../gyms/loads.ts'
import { Refusals } from '../gyms/refusals.ts'
import { isCleanText } from '../gyms/text.ts'
import { ownedStoredPhotos, PRIVATE_BUCKET } from '../photos/objects.ts'
import { RowError } from './columns.ts'
import type { PushContext } from './entities.ts'
import { inJson } from './sql.ts'

// The rules Postgres kept in CHECKs and triggers on private gyms and listings (supabase/migrations/
// 20261030000001_gyms.sql): clean_text on their text, valid_loads, and gym_equipment_check. The caps are triggers in
// migrations/0005_gyms_photos.sql.

type Row = Record<string, unknown>

function requireClean(row: Row, label: string, column: string, lines = false): void {
  const value = row[column]
  if (typeof value === 'string' && !isCleanText(value, lines)) {
    throw new RowError(`${label}.${column} has hidden or control characters`)
  }
}

/** A private gym: no hidden or control characters in its name or address. */
export function preparePrivateGym(row: Row, label: string): Row {
  requireClean(row, label, 'name')
  requireClean(row, label, 'address')
  return row
}

/** A private listing: clean text (notes may have lines), and loads the app can read, stored compact. */
export function preparePrivateListing(row: Row, label: string): Row {
  requireClean(row, label, 'notes', true)
  requireClean(row, label, 'private_brand')
  requireClean(row, label, 'private_model')
  const loads = parseLoads(JSON.parse(String(row.loads)))
  if (loads === null) throw new RowError(`${label}.loads is not a valid loads`)
  return { ...row, loads: JSON.stringify(loads) }
}

const strings = (values: readonly unknown[]) => [...new Set(values.filter((v): v is string => typeof v === 'string'))]

/**
 * gym_equipment_check for the caller's private listings, before anything is written:
 * - the gym is public or the caller's own private gym; any other reads as "unknown gym", so ids can't be probed;
 * - the item is its kind's generic one (brand and model stay on the listing, out of the shared catalogue);
 * - a photo that is new or changed is the caller's own upload to gym-photos-private, already stored.
 */
export async function checkPrivateListings(ctx: PushContext, rows: readonly Row[]): Promise<void> {
  const db = ctx.env.DB
  const listOf = (column: string) => JSON.stringify(strings(rows.map((r) => r[column])))
  const [gyms, items, stored] = await db.batch<{ id: string; photo_path: string | null }>([
    db.prepare(
      `SELECT id, NULL AS photo_path FROM gyms WHERE ${inJson('id', '?1')} AND (visibility = 'public' OR owner_id = ?2)`,
    ).bind(listOf('gym_id'), ctx.userId),
    db.prepare(
      `SELECT id, NULL AS photo_path FROM equipment_items WHERE ${inJson('id', '?1')} AND brand IS NULL AND model IS NULL`,
    ).bind(listOf('item_id')),
    db.prepare(`SELECT id, photo_path FROM gym_equipment WHERE ${inJson('id', '?1')}`).bind(listOf('id')),
  ])
  const knownGyms = new Set(gyms.results.map((r) => r.id))
  const genericItems = new Set(items.results.map((r) => r.id))
  rows.forEach((row, index) => {
    if (!knownGyms.has(row.gym_id as string)) throw new RowError(`rows[${index}].gym_id: unknown gym`)
    if (!genericItems.has(row.item_id as string)) {
      throw new RowError(`rows[${index}].item_id: a private listing uses a generic item`)
    }
  })
  const before = new Map(stored.results.map((r) => [r.id, r.photo_path]))
  const changed = strings(rows.filter((r) => r.photo_path !== null && r.photo_path !== before.get(r.id as string))
    .map((r) => r.photo_path))
  if (changed.length === 0) return
  const owned = await ownedStoredPhotos(ctx.env, ctx.userId, PRIVATE_BUCKET, changed)
  if (changed.some((name) => !owned.has(name))) throw Refusals.photoMissing()
}
```

- [ ] **Step 8: Add the two entities to `server/src/sync/entities.ts`**

Add to the imports:

```ts
import { checkPrivateListings, preparePrivateGym, preparePrivateListing } from './gym-rows.ts'
import { NOW_SQL } from './time.ts'
```

Add a helper next to `col` and `opt`:

```ts
/** visibility: the app always sends 'private'. Anything else breaks the table's *_private_has_owner CHECK. */
const privateRow: Column = { name: 'visibility', kind: 'text', fallback: 'private' }
```

Add to `ENTITIES`, after `bodyweight`:

```ts
  gyms: {
    table: 'gyms',
    owner: 'owner_id',
    scope: "visibility = 'private'",
    conflict: ['id'],
    ackKey: 'id',
    tiebreak: { column: 'id', kind: 'text' },
    columns: [
      col('id', 'uuid'), privateRow, col('name', 'text'), opt('address', 'text'), opt('latitude', 'real'),
      opt('longitude', 'real'), edited, deleted,
    ],
    insertOnly: { created_by: '?2', created_at: NOW_SQL },
    prepare: preparePrivateGym,
  },
  'gym-listings': {
    table: 'gym_equipment',
    owner: 'owner_id',
    scope: "visibility = 'private'",
    conflict: ['id'],
    ackKey: 'id',
    tiebreak: { column: 'id', kind: 'text' },
    columns: [
      col('id', 'uuid'), col('gym_id', 'uuid'), col('item_id', 'uuid'), privateRow, opt('photo_path', 'text'),
      col('loads', 'json'), col('quantity', 'int'), opt('notes', 'text'), opt('private_brand', 'text'),
      opt('private_model', 'text'), edited, deleted,
    ],
    insertOnly: { added_by: '?2', created_at: NOW_SQL },
    // PostgREST embedded the item as equipment_items(kind_id); GymListingDTO reads it there.
    pull: {
      select: ['(SELECT kind_id FROM equipment_items WHERE equipment_items.id = gym_equipment.item_id) AS item_kind_id'],
      shape: ({ item_kind_id, ...row }) => ({
        ...row,
        equipment_items: item_kind_id === null || item_kind_id === undefined ? null : { kind_id: item_kind_id },
      }),
    },
    prepare: preparePrivateListing,
    check: checkPrivateListings,
  },
```

- [ ] **Step 9: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  17 passed (17)`, `Tests  201 passed (201)`:
- 14 in `sync-gyms.test.ts`,
- 5 shared cases for `gyms` in `sync-rows.test.ts`,
- 1 more in the drift test.

- [ ] **Step 10: Commit**

```bash
git add server/migrations/0005_gyms_photos.sql server/src server/test
git commit -m "feat(server): private gyms and listings in sync, with their caps"
```

- [ ] **Step 11: Review**

Ask **code-reviewer** for spec compliance against `gym_equipment_check`, `check_private_*_cap`, the policies
`gyms_write_private` and `gym_equipment_write_private`, and spec section 4. Then **security-reviewer**:
- the owner check `IS NOT ?2`;
- that no pull returns `added_by`, `created_by` or another account's row;
- that `photo_path` can't name someone else's object.

---

### Task 5: Reading the shared catalogue

`GET /v1/gyms/public`, `GET /v1/gyms/:id/listings` and `GET /v1/items`. These are the views `public_gyms`,
`public_gym_equipment` and `public_equipment_items`, read under the policies they ran under.

**Files:**
- Create: `server/src/http/input.ts`, `server/src/gyms/catalogue.ts`, `server/src/gyms/routes.ts`
- Modify: `server/src/index.ts`, `server/test/gym-fixtures.ts`
- Test: `server/test/catalogue.test.ts`

- [ ] **Step 1: Write the fixture change and the failing tests**

In `server/test/gym-fixtures.ts`, give `insertListing` a creation time. Add `createdAt?: string` to its parameter type,
and bind `l.createdAt ?? T` for `created_at`. Its statement becomes:

```ts
  await env.DB.prepare(
    'INSERT INTO gym_equipment (id, gym_id, item_id, visibility, owner_id, photo_path, notes, added_by, status, ' +
      'client_updated_at, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?10)',
  ).bind(
    id,
    l.gym,
    l.item,
    l.visibility,
    l.visibility === 'private' ? (l.owner ?? null) : null,
    l.photo ?? null,
    l.notes ?? null,
    l.addedBy ?? null,
    l.status ?? 'active',
    T,
    l.createdAt ?? T,
  ).run()
```

`server/test/catalogue.test.ts` (from `gyms.test.sql` lines 39–49, 149–163, 336–453, `gym_moderation.test.sql`
lines 91–101 and 141–144, and `gym_rules.test.sql` lines 110–112):

```ts
import { describe, expect, it } from 'vitest'
import { block, confirm, genericItem, insertGym, insertItem, insertListing, makeAdmin, setStatus } from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'

type Json = Record<string, any>

async function get(token: string, path: string): Promise<Json> {
  const res = await request('GET', path, { token })
  expect(res.status).toBe(200)
  return res.json<Json>()
}

const gymAt = async (token: string, gymId: string) =>
  (await get(token, `/v1/gyms/public?place=${encodeURIComponent(`place-${gymId}`)}`)).gym as Json | null
const listingsOf = async (token: string, gymId: string, query = '') =>
  (await get(token, `/v1/gyms/${gymId}/listings${query}`)).rows as Json[]
const itemsOf = async (token: string, kind: string) => (await get(token, `/v1/items?kind=${kind}`)).rows as Json[]
const itemIn = (rows: Json[], id: string) => rows.find((row) => row.id === id)

const AUTHOR_COLUMNS = ['created_by', 'owner_id', 'added_by']

describe('a public gym by its place', () => {
  it('answers the active gym, with is_mine for whoever created it, and no author ids', async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const seen = await gymAt(a.token, gym)
    expect(seen).toMatchObject({
      id: gym, name: 'Test gym', address: null, latitude: null, longitude: null, maps_place_id: `place-${gym}`,
      status: 'active', is_mine: true,
    })
    for (const column of AUTHOR_COLUMNS) expect(seen).not.toHaveProperty(column)
    expect(await gymAt(b.token, gym)).toMatchObject({ id: gym, is_mine: false })
  })

  it('shows a flagged gym only to its creator and admins, and a removed one to nobody', async () => {
    const a = await signUp()
    const b = await signUp()
    const admin = await signUp()
    await makeAdmin(admin.userId)
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId, status: 'flagged' })
    expect(await gymAt(a.token, gym)).toMatchObject({ id: gym, status: 'flagged' })
    expect(await gymAt(b.token, gym)).toBeNull()
    expect(await gymAt(admin.token, gym)).toMatchObject({ id: gym })
    await setStatus('gyms', gym, 'removed')
    expect(await gymAt(a.token, gym)).toBeNull()
    expect(await gymAt(admin.token, gym)).toBeNull()
  })

  it('refuses a place id that could not be one', async () => {
    const { token } = await signUp()
    for (const query of ['', '?place=', '?place=a%0Ab', `?place=${'x'.repeat(201)}`]) {
      const res = await request('GET', `/v1/gyms/public${query}`, { token })
      expect(res.status).toBe(400)
      expect(await res.json()).toEqual({ error: { code: 'bad_request', message: 'invalid place' } })
    }
  })

  it('needs a session', async () => {
    const res = await request('GET', '/v1/gyms/public?place=p1')
    expect(res.status).toBe(401)
  })
})

describe("a gym's listings", () => {
  it("answers the active public listings with what is the caller's, and no author ids", async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const item = await genericItem('dumbbells')
    const photo = `${crypto.randomUUID()}.jpg`
    const listing = await insertListing({ gym, item, visibility: 'public', addedBy: a.userId, photo, notes: 'by the door' })
    await confirm(listing, b.userId)
    const [seen, ...more] = await listingsOf(b.token, gym)
    expect(more).toEqual([])
    expect(seen).toMatchObject({
      id: listing, gym_id: gym, item_id: item, kind_id: 'dumbbells', brand: null, model: null, photo_path: photo,
      loads: { type: 'none' }, quantity: 1, notes: 'by the door', status: 'active', confirm_count: 1, is_mine: false,
      confirmed_by_me: true, item_is_mine: false,
    })
    for (const column of AUTHOR_COLUMNS) expect(seen).not.toHaveProperty(column)
    expect((await listingsOf(a.token, gym))[0]).toMatchObject({ is_mine: true, confirmed_by_me: false })
  })

  it('hides a flagged listing from all but its author and admins, and a removed one from all but admins', async () => {
    const a = await signUp()
    const b = await signUp()
    const admin = await signUp()
    await makeAdmin(admin.userId)
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const listing = await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: a.userId })
    await setStatus('gym_equipment', listing, 'flagged')
    expect(await listingsOf(a.token, gym)).toHaveLength(1)
    expect(await listingsOf(b.token, gym)).toEqual([])
    expect(await listingsOf(admin.token, gym)).toHaveLength(1)
    await setStatus('gym_equipment', listing, 'removed')
    expect(await listingsOf(a.token, gym)).toEqual([])
    expect((await listingsOf(admin.token, gym))[0]).toMatchObject({ id: listing, status: 'removed' })
  })

  it('hides every listing of a removed gym, and of a removed item', async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const item = await insertItem({ brand: 'Acme', model: 'C1', createdBy: a.userId })
    await insertListing({ gym, item, visibility: 'public', addedBy: a.userId })
    expect(await listingsOf(b.token, gym)).toHaveLength(1)
    await setStatus('gyms', gym, 'removed')
    expect(await listingsOf(b.token, gym)).toEqual([])
    await setStatus('gyms', gym, 'active')
    await setStatus('equipment_items', item, 'removed')
    expect(await listingsOf(b.token, gym)).toEqual([])
  })

  it("hides a blocked author's listings, and listings of an item whose creator is blocked, from the blocker only",
    async () => {
      const author = await signUp()
      const creator = await signUp()
      const blocker = await signUp()
      const other = await signUp()
      const gym = await insertGym({ visibility: 'public', createdBy: author.userId })
      await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: author.userId })
      const item = await insertItem({ brand: 'Acme', model: 'C2', createdBy: creator.userId })
      await insertListing({ gym, item, visibility: 'public', addedBy: other.userId })
      expect(await listingsOf(blocker.token, gym)).toHaveLength(2)
      await block(blocker.userId, author.userId)
      expect((await listingsOf(blocker.token, gym)).map((l) => l.item_id)).toEqual([item])
      await block(blocker.userId, creator.userId)
      expect(await listingsOf(blocker.token, gym)).toEqual([])
      expect(await listingsOf(other.token, gym)).toHaveLength(2)
    })

  it('never answers private listings, even to their owner', async () => {
    const a = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    await insertListing({ gym, item: await genericItem(), visibility: 'private', owner: a.userId })
    expect(await listingsOf(a.token, gym)).toEqual([])
  })

  it('pages by offset and limit, oldest first', async () => {
    const a = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const item = await genericItem()
    const ids = []
    for (const createdAt of ['2026-11-07T10:00:01.000000Z', '2026-11-07T10:00:02.000000Z', '2026-11-07T10:00:03.000000Z']) {
      ids.push(await insertListing({ gym, item, visibility: 'public', addedBy: a.userId, createdAt }))
    }
    expect((await listingsOf(a.token, gym, '?limit=2')).map((l) => l.id)).toEqual(ids.slice(0, 2))
    expect((await listingsOf(a.token, gym, '?offset=2&limit=2')).map((l) => l.id)).toEqual(ids.slice(2))
    for (const query of ['?limit=501', '?limit=0', '?offset=-1', '?offset=x']) {
      expect((await request('GET', `/v1/gyms/${gym}/listings${query}`, { token: a.token })).status).toBe(400)
    }
  })
})

describe('the items of a kind', () => {
  it("answer the kind's generic item, and a branded one to others only once it has an active shared listing",
    async () => {
      const a = await signUp()
      const b = await signUp()
      const generic = await genericItem('kettlebells')
      expect(itemIn(await itemsOf(b.token, 'kettlebells'), generic)).toMatchObject({
        kind_id: 'kettlebells', brand: null, model: null, status: 'active', is_mine: false,
      })
      const item = await insertItem({ brand: 'Acme', model: 'K1', createdBy: a.userId, kind: 'kettlebells' })
      expect(itemIn(await itemsOf(b.token, 'kettlebells'), item)).toBeUndefined()
      expect(itemIn(await itemsOf(a.token, 'kettlebells'), item)).toMatchObject({ is_mine: true, gym_count: 0 })
      const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
      await insertListing({ gym, item, visibility: 'public', addedBy: a.userId })
      expect(itemIn(await itemsOf(b.token, 'kettlebells'), item)).toMatchObject({ brand: 'Acme', model: 'K1', gym_count: 1 })
      for (const column of AUTHOR_COLUMNS) expect(itemIn(await itemsOf(b.token, 'kettlebells'), item)).not.toHaveProperty(column)
    })

  it('take the photo from the most confirmed listing, the oldest on a tie, skipping flagged ones and blocked authors',
    async () => {
      const a = await signUp()
      const c = await signUp()
      const viewer = await signUp()
      const item = await insertItem({ brand: 'Acme', model: 'K2', createdBy: a.userId, kind: 'kettlebells' })
      const photos = [`${crypto.randomUUID()}.jpg`, `${crypto.randomUUID()}.jpg`]
      const first = await insertListing({
        gym: await insertGym({ visibility: 'public', createdBy: a.userId }), item, visibility: 'public', addedBy: a.userId,
        photo: photos[0], createdAt: '2026-11-07T10:00:01.000000Z',
      })
      const second = await insertListing({
        gym: await insertGym({ visibility: 'public', createdBy: c.userId }), item, visibility: 'public', addedBy: c.userId,
        photo: photos[1], createdAt: '2026-11-07T10:00:02.000000Z',
      })
      const photoFor = async (token: string) => itemIn(await itemsOf(token, 'kettlebells'), item)
      expect(await photoFor(viewer.token)).toMatchObject({ photo_path: photos[0], photo_listing_id: first })
      await confirm(second, viewer.userId)
      expect(await photoFor(viewer.token)).toMatchObject({ photo_path: photos[1], photo_listing_id: second })
      await block(viewer.userId, c.userId)
      expect(await photoFor(viewer.token)).toMatchObject({ photo_path: photos[0] })
      expect(await photoFor(a.token)).toMatchObject({ photo_path: photos[1] })
      await setStatus('gym_equipment', second, 'flagged')
      expect(await photoFor(a.token)).toMatchObject({ photo_path: photos[0] })
      await setStatus('gym_equipment', first, 'removed')
      expect(await photoFor(a.token)).toMatchObject({ photo_path: null, photo_listing_id: null })
    })

  it("never take a private listing's photo, even for its owner", async () => {
    const a = await signUp()
    const generic = await genericItem('medicine-ball')
    const gym = await insertGym({ visibility: 'private', owner: a.userId })
    await insertListing({ gym, item: generic, visibility: 'private', owner: a.userId, photo: `${crypto.randomUUID()}.jpg` })
    expect(itemIn(await itemsOf(a.token, 'medicine-ball'), generic)).toMatchObject({ photo_path: null, gym_count: 0 })
  })

  it('count the distinct gyms that list one', async () => {
    const a = await signUp()
    const item = await insertItem({ brand: 'Acme', model: 'K3', createdBy: a.userId, kind: 'kettlebells' })
    const one = await insertGym({ visibility: 'public', createdBy: a.userId })
    const two = await insertGym({ visibility: 'public', createdBy: a.userId })
    for (const gym of [one, one, two]) await insertListing({ gym, item, visibility: 'public', addedBy: a.userId })
    expect(itemIn(await itemsOf(a.token, 'kettlebells'), item)).toMatchObject({ gym_count: 2 })
  })

  it('refuse a kind that could not be one', async () => {
    const { token } = await signUp()
    const res = await request('GET', '/v1/items?kind=Not%20A%20Kind', { token })
    expect(res.status).toBe(400)
    expect(await res.json()).toEqual({ error: { code: 'bad_request', message: 'invalid kind' } })
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/catalogue.test.ts`
Expected: FAIL, with `404 not_found` from the three routes.

- [ ] **Step 3: Write `server/src/http/input.ts`**

```ts
import { isStorableText } from '../sync/columns.ts'
import { ApiError } from './errors.ts'

// Reading the JSON bodies and the queries of the gym, photo and moderation routes. A value of the wrong type answers
// 400 bad_request, as Postgres refused a function argument it couldn't take (22P02, 22023).

export const badRequest = (message: string) => new ApiError(400, 'bad_request', message)

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** A JSON object body, or 400. */
export function objectBody(body: unknown): Record<string, unknown> {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    throw badRequest('The body must be a JSON object.')
  }
  return body as Record<string, unknown>
}

/** A UUID, lowercased (D1 compares text). */
export function uuidOf(value: unknown, name: string): string {
  if (typeof value !== 'string' || !UUID.test(value)) throw badRequest(`${name} must be a UUID.`)
  return value.toLowerCase()
}

export function textOf(value: unknown, name: string): string {
  if (typeof value !== 'string' || !isStorableText(value)) throw badRequest(`${name} must be text.`)
  return value
}

export const textOrNull = (value: unknown, name: string): string | null =>
  value === undefined || value === null ? null : textOf(value, name)

export function numberOrNull(value: unknown, name: string): number | null {
  if (value === undefined || value === null) return null
  if (typeof value !== 'number' || !Number.isFinite(value)) throw badRequest(`${name} must be a number.`)
  return value
}

export function intOrNull(value: unknown, name: string): number | null {
  if (value === undefined || value === null) return null
  if (typeof value !== 'number' || !Number.isSafeInteger(value)) throw badRequest(`${name} must be a whole number.`)
  return value
}

export function boolOr(value: unknown, name: string, fallback: boolean): boolean {
  if (value === undefined || value === null) return fallback
  if (typeof value !== 'boolean') throw badRequest(`${name} must be true or false.`)
  return value
}
```

- [ ] **Step 4: Write `server/src/gyms/catalogue.ts`**

```ts
import { badRequest } from '../http/input.ts'
import { gymReadable, itemReadable, listingReadable } from './visibility.ts'

// What the app reads of the shared catalogue: the public_gyms, public_gym_equipment and public_equipment_items views
// (supabase/migrations/20261030000001_gyms.sql) under the read policies they ran under, for the caller (?1). Author ids
// never leave the server: is_mine, confirmed_by_me and item_is_mine say what is the caller's.

/** find_or_create_gym's place rule, also the gyms CHECK. */
export const PLACE_ID = /^[A-Za-z0-9._:+/=-]{1,200}$/
export const KIND_ID = /^[a-z0-9-]{1,40}$/
/** A gym holds at most 300 active public listings, so the app reads one page, two at most. */
export const LISTINGS_PAGE = 500
/** PostgREST's max_rows, which capped the items view. */
const ITEMS_MAX = 1000
const OFFSET_MAX = 100_000

type Row = Record<string, unknown>
const flag = (value: unknown) => value === 1

export interface Page {
  readonly offset: number
  readonly limit: number
}

function whole(raw: string | undefined, name: string, fallback: number, min: number, max: number): number {
  if (raw === undefined) return fallback
  const value = /^\d+$/.test(raw) ? Number(raw) : Number.NaN
  if (!(value >= min && value <= max)) throw badRequest(`${name} must be ${min} to ${max}.`)
  return value
}

/** `?offset=&limit=`, as PostgREST's range: up to 500 listings a page. */
export const pageOf = (query: Record<string, string | undefined>): Page => ({
  offset: whole(query.offset, 'offset', 0, 0, OFFSET_MAX),
  limit: whole(query.limit, 'limit', LISTINGS_PAGE, 1, LISTINGS_PAGE),
})

/** The public gym of a Maps place, newest first, as the app asked public_gyms; null when the caller can't see one. */
export async function publicGym(db: D1Database, me: string, place: string): Promise<Row | null> {
  if (!PLACE_ID.test(place)) throw badRequest('invalid place')
  const row = await db.prepare(
    `SELECT g.id, g.name, g.address, g.latitude, g.longitude, g.maps_place_id, g.status, g.created_at, g.updated_at,
       coalesce(g.created_by = ?1, 0) AS is_mine
     FROM gyms g
     WHERE g.visibility = 'public' AND g.maps_place_id = ?2 AND g.status <> 'removed' AND ${gymReadable('g', '?1')}
     ORDER BY g.created_at DESC LIMIT 1`,
  ).bind(me, place).first<Row>()
  return row === null ? null : { ...row, is_mine: flag(row.is_mine) }
}

/** One page of a gym's public listings, oldest first (public_gym_equipment, ordered by created_at and id). */
export async function publicListings(db: D1Database, me: string, gymId: string, page: Page): Promise<Row[]> {
  const { results } = await db.prepare(
    `SELECT e.id, e.gym_id, e.item_id, i.kind_id, i.brand, i.model, e.photo_path, e.loads, e.quantity, e.notes,
       e.status, e.confirm_count, e.created_at, e.updated_at, coalesce(e.added_by = ?1, 0) AS is_mine,
       EXISTS (SELECT 1 FROM equipment_confirmations c WHERE c.listing_id = e.id AND c.user_id = ?1) AS confirmed_by_me,
       coalesce(i.created_by = ?1, 0) AS item_is_mine
     FROM gym_equipment e JOIN equipment_items i ON i.id = e.item_id JOIN gyms g ON g.id = e.gym_id
     WHERE e.gym_id = ?2 AND e.visibility = 'public' AND ${listingReadable('e', '?1')} AND ${itemReadable('i', '?1')}
       AND ${gymReadable('g', '?1')}
     ORDER BY e.created_at, e.id LIMIT ?3 OFFSET ?4`,
  ).bind(me, gymId, page.limit, page.offset).all<Row>()
  return results.map((row) => ({
    ...row,
    loads: JSON.parse(String(row.loads)),
    is_mine: flag(row.is_mine),
    confirmed_by_me: flag(row.confirmed_by_me),
    item_is_mine: flag(row.item_is_mine),
  }))
}

/**
 * A kind's active items the caller can read (public_equipment_items). An item's photo is its best shared listing's:
 * the most confirmed, then the oldest. It is never stored on the item, so a listing that is removed, flagged or loses
 * its photo, or whose author is blocked, simply lets the next one show.
 */
export async function publicItems(db: D1Database, me: string, kind: string): Promise<Row[]> {
  if (!KIND_ID.test(kind)) throw badRequest('invalid kind')
  const { results } = await db.prepare(
    `SELECT i.id, i.kind_id, i.brand, i.model, p.photo_path, p.id AS photo_listing_id, i.status, i.created_at,
       i.updated_at, coalesce(i.created_by = ?1, 0) AS is_mine,
       (SELECT count(DISTINCT c.gym_id) FROM gym_equipment c WHERE c.item_id = i.id AND c.visibility = 'public'
          AND c.status = 'active' AND ${listingReadable('c', '?1')}) AS gym_count
     FROM equipment_items i
     LEFT JOIN gym_equipment p ON p.id = (SELECT b.id FROM gym_equipment b WHERE b.item_id = i.id
       AND b.visibility = 'public' AND b.status = 'active' AND b.photo_path IS NOT NULL AND ${listingReadable('b', '?1')}
       ORDER BY b.confirm_count DESC, b.created_at, b.id LIMIT 1)
     WHERE i.kind_id = ?2 AND i.status = 'active' AND ${itemReadable('i', '?1')}
     ORDER BY i.id LIMIT ${ITEMS_MAX}`,
  ).bind(me, kind).all<Row>()
  return results.map((row) => ({ ...row, is_mine: flag(row.is_mine) }))
}
```

- [ ] **Step 5: Write `server/src/gyms/routes.ts` and mount it**

```ts
import { Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { uuidOf } from '../http/input.ts'
import { pageOf, publicGym, publicItems, publicListings } from './catalogue.ts'

/** /v1/gyms, /v1/items and /v1/listings: the shared catalogue (spec section 3, "Gyms"). */
export const catalogueRoutes = new Hono<AppEnv>()

catalogueRoutes.get('/gyms/public', async (c) =>
  c.json({ gym: await publicGym(c.env.DB, c.var.userId, c.req.query('place') ?? '') }))

catalogueRoutes.get('/gyms/:id/listings', async (c) => {
  const gymId = uuidOf(c.req.param('id'), 'id')
  return c.json({ rows: await publicListings(c.env.DB, c.var.userId, gymId, pageOf(c.req.query())) })
})

catalogueRoutes.get('/items', async (c) =>
  c.json({ rows: await publicItems(c.env.DB, c.var.userId, c.req.query('kind') ?? '') }))
```

In `server/src/index.ts`, import it and mount it after the account routes:

```ts
import { catalogueRoutes } from './gyms/routes.ts'
```

```ts
v1.route('/', catalogueRoutes)
```

- [ ] **Step 6: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  18 passed (18)`, `Tests  216 passed (216)`.

- [ ] **Step 7: Commit**

```bash
git add server/src/http/input.ts server/src/gyms server/src/index.ts server/test/gym-fixtures.ts \
  server/test/catalogue.test.ts
git commit -m "feat(server): read the shared gym catalogue"
```

- [ ] **Step 8: Review**

Ask **code-reviewer** to check each read against its view and policy: `public_gyms` with `gyms_read`,
`public_gym_equipment` with `gym_equipment_read` + `equipment_items_read` + `gyms_read` (the view's joins ran under all
three), and `public_equipment_items` with its lateral photo. Then **security-reviewer**: no author column in any answer,
and no private row.

---

### Task 6: Sharing: find or create a gym, share a listing, confirm one

`POST /v1/gyms/find-or-create`, `POST /v1/listings/share` and `POST /v1/listings/:id/confirm`, with their daily
limits: 10 new gyms, 30 shares and 100 confirmations, plus the 300 active listings a gym holds.

**Files:**
- Create: `server/src/gyms/share.ts`
- Modify: `server/src/gyms/routes.ts`, `server/src/sync/time.ts`, `server/src/http/errors.ts`, `server/test/gym-fixtures.ts`
- Test: `server/test/share.test.ts`

- [ ] **Step 1: Write the fixtures and the failing tests**

Add this import at the top of `server/test/gym-fixtures.ts`, and the helpers after it at the end of the file:

```ts
import { NOW_SQL } from '../src/sync/time.ts'
```

```ts
/** A timestamp two days back: outside every daily limit. */
export const DAYS_AGO = '2020-01-01T00:00:00.000000Z'

/** `count` public gyms the account created just now, as find_or_create_gym would have. */
export async function gymsCreatedToday(userId: string, count: number) {
  const ids = Array.from({ length: count }, () => crypto.randomUUID())
  await env.DB.prepare(
    `INSERT INTO gyms (id, visibility, name, maps_place_id, created_by, status, client_updated_at, created_at, updated_at)
     SELECT value, 'public', 'Earlier gym', 'place-' || value, ?2, 'active', ${NOW_SQL}, ${NOW_SQL}, ${NOW_SQL}
     FROM json_each(?1)`,
  ).bind(JSON.stringify(ids), userId).run()
  return ids
}

/** `count` active public listings at a gym, added just now by `addedBy`, as share_listing would have. */
export async function listingsSharedToday(gym: string, addedBy: string, count: number) {
  const ids = Array.from({ length: count }, () => crypto.randomUUID())
  await env.DB.prepare(
    `INSERT INTO gym_equipment (id, gym_id, item_id, visibility, added_by, status, client_updated_at, created_at,
       updated_at)
     SELECT value, ?2, ?3, 'public', ?4, 'active', ${NOW_SQL}, ${NOW_SQL}, ${NOW_SQL} FROM json_each(?1)`,
  ).bind(JSON.stringify(ids), gym, await genericItem(), addedBy).run()
  return ids
}

/** Moves every row the account wrote to `table` (by `column`) two days back. */
export async function agedRows(table: string, column: string, userId: string) {
  await env.DB.prepare(`UPDATE ${table} SET created_at = ?2 WHERE ${column} = ?1`).bind(userId, DAYS_AGO).run()
}
```

`server/test/share.test.ts` (from `gyms.test.sql` lines 59–144, 166–173, 202, 369–392 and 464–468, and
`gym_rules.test.sql` lines 39–46 and 83–101):

```ts
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import {
  agedRows, block, confirm, genericItem, gymsCreatedToday, insertGym, insertListing, listingsSharedToday, setStatus,
  uploadedPhoto,
} from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'

type Json = Record<string, any>

const place = () => `place-${crypto.randomUUID()}`

const findOrCreate = (token: string, body: Json) => request('POST', '/v1/gyms/find-or-create', { token, body })

async function gymFor(token: string, body: Json): Promise<string> {
  const res = await findOrCreate(token, body)
  expect(res.status).toBe(200)
  return (await res.json<{ id: string }>()).id
}

const shareBody = (gymId: string, overrides: Json = {}): Json => ({
  listing_id: crypto.randomUUID().toUpperCase(), gym_id: gymId, kind_id: 'dumbbells', brand: null, model: null,
  loads: { type: 'none' }, quantity: 1, notes: null, photo_path: null, force_new: false, ...overrides,
})

const share = (token: string, body: Json) => request('POST', '/v1/listings/share', { token, body })

async function answer(res: Response, status = 200): Promise<Json> {
  expect(res.status).toBe(status)
  return res.json<Json>()
}

const refusalOf = async (res: Response, status = 422) => (await answer(res, status)).error as { code: string; message: string }

const confirmOf = (token: string, listing: string) => request('POST', `/v1/listings/${listing}/confirm`, { token })

describe('find or create a gym', () => {
  it('creates a public gym on the first share of a place, trims its text, and answers the same gym after', async () => {
    const a = await signUp()
    const b = await signUp()
    const where = place()
    const id = await gymFor(a.token, { maps_place_id: where, name: ' Iron Works ', address: ' 1 Main St ', latitude: 52.1, longitude: 4.3 })
    const again = await gymFor(b.token, { maps_place_id: where, name: 'Other name', address: null, latitude: 0, longitude: 0 })
    expect(again).toBe(id)
    const stored = await env.DB.prepare('SELECT name, address, latitude, created_by, visibility FROM gyms WHERE id = ?1')
      .bind(id).first()
    expect(stored).toEqual({ name: 'Iron Works', address: '1 Main St', latitude: 52.1, created_by: a.userId, visibility: 'public' })
    const seen = await answer(await request('GET', `/v1/gyms/public?place=${where}`, { token: a.token }))
    expect(seen.gym).toMatchObject({ id, is_mine: true })
  })

  it('refuses a place id that could not be one, and a name of hidden characters', async () => {
    const { token } = await signUp()
    for (const maps_place_id of ['', 'a\nb', 'x'.repeat(201), 7]) {
      expect(await refusalOf(await findOrCreate(token, { maps_place_id, name: 'Gym' }), 400))
        .toEqual({ code: 'bad_request', message: 'invalid place' })
    }
    expect((await refusalOf(await findOrCreate(token, { maps_place_id: place(), name: '​' }))).code).toBe('row_rejected')
    expect((await refusalOf(await findOrCreate(token, { maps_place_id: place(), name: '   ' }))).code).toBe('row_rejected')
  })

  it('creates 10 gyms a day; the 11th is refused, a known place still answers, and older ones do not count', async () => {
    const { token, userId } = await signUp()
    await gymsCreatedToday(userId, 9)
    await gymFor(token, { maps_place_id: place(), name: 'Tenth' })
    expect(await refusalOf(await findOrCreate(token, { maps_place_id: place(), name: 'Eleventh' }))).toEqual({
      code: 'daily_limit', message: "You've shared a lot today. Try again tomorrow.",
    })
    const known = await insertGym({ visibility: 'public' })
    expect(await gymFor(token, { maps_place_id: `place-${known}`, name: 'Known' })).toBe(known)
    await agedRows('gyms', 'created_by', userId)
    await gymFor(token, { maps_place_id: place(), name: 'Tomorrow' })
  })

  it('gives a removed gym its place back', async () => {
    const { token } = await signUp()
    const where = place()
    const first = await gymFor(token, { maps_place_id: where, name: 'First' })
    await setStatus('gyms', first, 'removed')
    const second = await gymFor(token, { maps_place_id: where, name: 'Second' })
    expect(second).not.toBe(first)
  })
})

describe('share a listing', () => {
  it('creates a listing, answers a retry with the same id as created, and offers duplicates of the kind', async () => {
    const a = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    const body = shareBody(gym, { notes: 'by the door\nleft side' })
    const id = String(body.listing_id).toLowerCase()
    expect(await answer(await share(a.token, body))).toEqual({ status: 'created', listing_id: id })
    expect(await answer(await share(a.token, body))).toEqual({ status: 'created', listing_id: id })
    const offered = await answer(await share(a.token, shareBody(gym)))
    expect(offered).toEqual({
      status: 'duplicates',
      listings: [{ id, kind_id: 'dumbbells', brand: null, model: null, photo_path: null, loads: { type: 'none' }, quantity: 1, confirm_count: 0 }],
    })
    const forced = shareBody(gym, { brand: 'Hammer Strength', model: 'Pro', loads: { type: 'plates' }, quantity: 2, force_new: true })
    expect((await answer(await share(a.token, forced))).status).toBe('created')
    const count = await env.DB.prepare("SELECT count(*) AS n FROM gym_equipment WHERE gym_id = ?1 AND visibility = 'public'")
      .bind(gym).first<{ n: number }>()
    expect(count!.n).toBe(2)
  })

  it('finds a catalogue item by brand and model in any case, in every script', async () => {
    const a = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    for (const brand of ['Ärger Fitness', ' ärger FITNESS ']) {
      await answer(await share(a.token, shareBody(gym, { brand, model: 'Ü1', force_new: true })))
    }
    const items = await env.DB.prepare("SELECT brand FROM equipment_items WHERE brand_key = 'ärger fitness'").all()
    expect(items.results).toEqual([{ brand: 'Ärger Fitness' }])
  })

  it("leaves blocked authors' listings out of the duplicates", async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    await answer(await share(a.token, shareBody(gym)))
    await block(b.userId, a.userId)
    expect((await answer(await share(b.token, shareBody(gym)))).status).toBe('created')
  })

  it("takes the caller's own stored photo once, and refuses someone else's, a missing or a made-up one", async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    const mine = await uploadedPhoto(a.userId, 'gym-photos')
    expect((await answer(await share(a.token, shareBody(gym, { photo_path: mine })))).status).toBe('created')
    expect(await refusalOf(await share(a.token, shareBody(gym, { photo_path: mine, force_new: true })))).toEqual({
      code: 'photo_in_use', message: 'That photo already belongs to a listing.',
    })
    const theirs = await uploadedPhoto(b.userId, 'gym-photos')
    const unfinished = await uploadedPhoto(a.userId, 'gym-photos', { stored: false })
    const privateOne = await uploadedPhoto(a.userId, 'gym-photos-private')
    for (const photo_path of [theirs, unfinished, privateOne, '../evil.jpg']) {
      expect((await refusalOf(await share(a.token, shareBody(gym, { photo_path, force_new: true })))).code)
        .toBe('photo_missing')
    }
  })

  it('refuses loads the app could not read, an unknown kind, and text the CHECKs refuse', async () => {
    const a = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    const refused = async (overrides: Json, status: number) => refusalOf(await share(a.token, shareBody(gym, { force_new: true, ...overrides })), status)
    expect(await refused({ loads: { type: 'stack', maxKg: -1 } }, 400)).toEqual({ code: 'bad_request', message: 'invalid loads' })
    expect(await refused({ loads: { type: 'plates', html: '<script>' } }, 400)).toMatchObject({ message: 'invalid loads' })
    expect(await refused({ kind_id: 'no-such-kind' }, 400)).toEqual({ code: 'bad_request', message: 'unknown kind' })
    expect(await refused({ brand: 'Acme‮' }, 422)).toEqual({ code: 'row_rejected', message: 'brand has hidden or control characters' })
    expect((await refused({ brand: 'x'.repeat(61) }, 422)).code).toBe('row_rejected')
    expect((await refused({ quantity: 51 }, 422)).code).toBe('row_rejected')
    expect((await refused({ quantity: 1.5 }, 400)).code).toBe('bad_request')
  })

  it("refuses a gym that isn't public and active, and a listing id that isn't the caller's public listing", async () => {
    const a = await signUp()
    const b = await signUp()
    const flagged = await insertGym({ visibility: 'public', createdBy: a.userId, status: 'flagged' })
    const privateGym = await insertGym({ visibility: 'private', owner: a.userId })
    for (const gym of [flagged, privateGym, crypto.randomUUID()]) {
      expect((await refusalOf(await share(a.token, shareBody(gym)))).code).toBe('gym_not_shareable')
    }
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    const mine = shareBody(gym)
    await answer(await share(a.token, mine))
    expect((await refusalOf(await share(b.token, { ...mine }), 403)).code).toBe('not_allowed')
    const privateListing = await insertListing({ gym: privateGym, item: await genericItem(), visibility: 'private', owner: a.userId })
    expect((await refusalOf(await share(a.token, shareBody(gym, { listing_id: privateListing })), 403)).code).toBe('not_allowed')
  })

  it('shares 30 a day; the 31st is refused, and older shares do not count', async () => {
    const a = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    await listingsSharedToday(gym, a.userId, 29)
    expect((await answer(await share(a.token, shareBody(gym, { force_new: true })))).status).toBe('created')
    expect((await refusalOf(await share(a.token, shareBody(gym, { force_new: true })))).code).toBe('daily_limit')
    await agedRows('gym_equipment', 'added_by', a.userId)
    expect((await answer(await share(a.token, shareBody(gym, { force_new: true })))).status).toBe('created')
  })

  it('holds 300 active listings a gym; a retry still succeeds there, and a removed listing frees a place', async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    const mine = shareBody(gym)
    await answer(await share(a.token, mine))
    const others = await listingsSharedToday(gym, (await signUp()).userId, 299)
    expect(await refusalOf(await share(b.token, shareBody(gym, { force_new: true })))).toEqual({
      code: 'gym_full', message: 'This gym has as much shared equipment as it can hold.',
    })
    expect((await answer(await share(a.token, mine))).status).toBe('created')
    await setStatus('gym_equipment', others[0], 'removed')
    expect((await answer(await share(b.token, shareBody(gym, { force_new: true })))).status).toBe('created')
  })

  it('creates exactly 30 when 35 shares arrive together', async () => {
    const a = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    const answers = await Promise.all(Array.from({ length: 35 }, () => share(a.token, shareBody(gym, { force_new: true }))))
    expect(answers.filter((res) => res.status === 200)).toHaveLength(30)
    expect(answers.filter((res) => res.status === 422)).toHaveLength(5)
  })
})

describe('confirm a listing', () => {
  it("counts each account once, and adds nothing for the listing's author", async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    const { listing_id } = await answer(await share(a.token, shareBody(gym)))
    expect(await answer(await confirmOf(b.token, listing_id))).toEqual({ confirm_count: 1 })
    expect(await answer(await confirmOf(b.token, listing_id))).toEqual({ confirm_count: 1 })
    expect(await answer(await confirmOf(a.token, listing_id))).toEqual({ confirm_count: 1 })
    const seen = await answer(await request('GET', `/v1/gyms/${gym}/listings`, { token: b.token }))
    expect(seen.rows[0]).toMatchObject({ confirm_count: 1, confirmed_by_me: true })
  })

  it("refuses a listing that is flagged, under a removed gym, by a blocked author, or isn't there", async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const item = await genericItem()
    const flagged = await insertListing({ gym, item, visibility: 'public', addedBy: a.userId, status: 'flagged' })
    const removedGym = await insertGym({ visibility: 'public', createdBy: a.userId, status: 'removed' })
    const underRemoved = await insertListing({ gym: removedGym, item, visibility: 'public', addedBy: a.userId })
    const byBlocked = await insertListing({ gym, item, visibility: 'public', addedBy: a.userId })
    await block(b.userId, a.userId)
    for (const listing of [flagged, underRemoved, byBlocked, crypto.randomUUID()]) {
      expect(await refusalOf(await confirmOf(b.token, listing))).toEqual({ code: 'unknown_listing', message: 'unknown listing' })
    }
  })

  it('confirms 100 a day; the 101st is refused, but an earlier confirmation still answers', async () => {
    const author = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: author.userId })
    const listings = await listingsSharedToday(gym, author.userId, 101)
    for (const listing of listings.slice(0, 99)) await confirm(listing, b.userId)
    await env.DB.prepare('UPDATE equipment_confirmations SET created_at = (strftime(\'%Y-%m-%dT%H:%M:%f\', \'now\') || \'000Z\') WHERE user_id = ?1')
      .bind(b.userId).run()
    expect(await answer(await confirmOf(b.token, listings[99]))).toEqual({ confirm_count: 1 })
    expect((await refusalOf(await confirmOf(b.token, listings[100]))).code).toBe('daily_limit')
    expect(await answer(await confirmOf(b.token, listings[0]))).toEqual({ confirm_count: 1 })
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/share.test.ts`
Expected: FAIL, with `404 not_found` from the three routes.

- [ ] **Step 3: Add the day window to `server/src/sync/time.ts` and 503 to the error statuses**

In `server/src/sync/time.ts`, after `NOW_SQL`:

```ts
/** A day before the server's clock, in the stored form: the start of every rolling daily limit. */
export const DAY_AGO_SQL = `(strftime('%Y-%m-%dT%H:%M:%f', 'now', '-1 day') || '000Z')`
```

In `server/src/http/errors.ts`, add `503` to `ErrorStatus`:

```ts
export type ErrorStatus = 400 | 401 | 403 | 404 | 409 | 413 | 422 | 429 | 500 | 503
```

- [ ] **Step 4: Write `server/src/gyms/share.ts`**

```ts
import type { Env } from '../env.ts'
import { ApiError } from '../http/errors.ts'
import { badRequest, boolOr, intOrNull, numberOrNull, objectBody, textOf, textOrNull, uuidOf } from '../http/input.ts'
import { ownedStoredPhotos, SHARED_BUCKET } from '../photos/objects.ts'
import { DomainLimits } from '../shared/domain-limits.ts'
import { DAY_AGO_SQL, laterStamp, NOW_SQL } from '../sync/time.ts'
import { PLACE_ID } from './catalogue.ts'
import { parseLoads } from './loads.ts'
import { Refusals } from './refusals.ts'
import { foldKey, requireCleanText, trimmedOrNull, trimSpaces } from './text.ts'
import { blockedAuthor } from './visibility.ts'

// Writing public gym data: find_or_create_gym, share_listing and confirm_listing (supabase/migrations/
// 20261030000002_gym_functions.sql). Each daily limit sits in the one statement or batch that writes, so requests that
// arrive together can't each see a count under it: D1 runs writes one at a time. When nothing was written, a read
// afterwards says why.

type Row = Record<string, unknown>

// ---- find_or_create_gym ----

export interface GymPlace {
  readonly mapsPlaceId: string
  readonly name: string
  readonly address: string | null
  readonly latitude: number | null
  readonly longitude: number | null
}

export function parsePlace(body: unknown): GymPlace {
  const b = objectBody(body)
  if (typeof b.maps_place_id !== 'string' || !PLACE_ID.test(b.maps_place_id)) throw badRequest('invalid place')
  return {
    mapsPlaceId: b.maps_place_id,
    name: textOf(b.name, 'name'),
    address: textOrNull(b.address, 'address'),
    latitude: numberOrNull(b.latitude, 'latitude'),
    longitude: numberOrNull(b.longitude, 'longitude'),
  }
}

const FIND_GYM = "SELECT id FROM gyms WHERE visibility = 'public' AND status <> 'removed' AND maps_place_id = ?1"

/** A removed gym gives its place back (the partial unique index), so one bad gym can't hold a real place forever. */
const CREATE_GYM = `INSERT INTO gyms (id, visibility, name, address, latitude, longitude, maps_place_id, created_by,
    status, client_updated_at, created_at, updated_at)
SELECT ?1, 'public', ?2, ?3, ?4, ?5, ?6, ?7, 'active', ${NOW_SQL}, ${NOW_SQL}, ${NOW_SQL}
WHERE (SELECT count(*) FROM gyms WHERE visibility = 'public' AND created_by = ?7
  AND created_at > ${DAY_AGO_SQL}) < ${DomainLimits.dailyGymCreations}
ON CONFLICT (maps_place_id) WHERE visibility = 'public' AND status <> 'removed' DO NOTHING
RETURNING id`

/** The public gym for a Maps place, created on the first share. The first caller's text stands. */
export async function findOrCreateGym(db: D1Database, me: string, place: GymPlace): Promise<string> {
  const found = await db.prepare(FIND_GYM).bind(place.mapsPlaceId).first<{ id: string }>()
  if (found) return found.id
  const name = trimSpaces(place.name)
  const address = trimmedOrNull(place.address)
  requireCleanText(name, 'name')
  requireCleanText(address, 'address')
  const { results } = await db.prepare(CREATE_GYM)
    .bind(crypto.randomUUID(), name, address, place.latitude, place.longitude, place.mapsPlaceId, me)
    .all<{ id: string }>()
  if (results.length > 0) return results[0].id
  // Someone else created it in the meantime, or the day's 10 are used up.
  const raced = await db.prepare(FIND_GYM).bind(place.mapsPlaceId).first<{ id: string }>()
  if (raced) return raced.id
  throw Refusals.dailyLimit()
}

// ---- share_listing ----

export interface ShareInput {
  readonly listingId: string
  readonly gymId: string
  readonly kindId: string
  readonly brand: string | null
  readonly model: string | null
  readonly loads: unknown
  readonly quantity: number | null
  readonly notes: string | null
  readonly photoPath: string | null
  readonly forceNew: boolean
}

export function parseShare(body: unknown): ShareInput {
  const b = objectBody(body)
  return {
    listingId: uuidOf(b.listing_id, 'listing_id'),
    gymId: uuidOf(b.gym_id, 'gym_id'),
    kindId: textOf(b.kind_id, 'kind_id'),
    brand: textOrNull(b.brand, 'brand'),
    model: textOrNull(b.model, 'model'),
    loads: b.loads,
    quantity: intOrNull(b.quantity, 'quantity'),
    notes: textOrNull(b.notes, 'notes'),
    photoPath: textOrNull(b.photo_path, 'photo_path'),
    forceNew: boolOr(b.force_new, 'force_new', false),
  }
}

export type ShareAnswer =
  | { readonly status: 'created'; readonly listing_id: string }
  | { readonly status: 'duplicates'; readonly listings: readonly Row[] }

/**
 * What every write of a share repeats, so the item and the listing are written together or not at all:
 * ?1 the caller, ?2 the listing id, ?3 the gym, ?6 the photo.
 */
const SHARE_GATE = `(SELECT count(*) FROM gym_equipment WHERE visibility = 'public' AND added_by = ?1
    AND created_at > ${DAY_AGO_SQL}) < ${DomainLimits.dailyShares}
  AND (?6 IS NULL OR (NOT EXISTS (SELECT 1 FROM gym_equipment WHERE photo_path = ?6)
    AND EXISTS (SELECT 1 FROM photo_objects WHERE bucket = 'gym-photos' AND name = ?6 AND owner_id = ?1)))
  AND (SELECT count(*) FROM gym_equipment WHERE gym_id = ?3 AND visibility = 'public' AND status = 'active'
    AND deleted_at IS NULL) < ${DomainLimits.gymActiveListingsMax}
  AND EXISTS (SELECT 1 FROM gyms WHERE id = ?3 AND visibility = 'public' AND status = 'active')
  AND NOT EXISTS (SELECT 1 FROM gym_equipment WHERE id = ?2)`

/** ensure_equipment_item: ?4 the kind, ?5 the brand, ?7 the model, ?8 and ?9 their fold keys, ?10 a new id. */
const ENSURE_ITEM = `INSERT INTO equipment_items (id, kind_id, brand, model, brand_key, model_key, created_by, status,
    created_at, updated_at)
SELECT ?10, ?4, ?5, ?7, ?8, ?9, ?1, 'active', ${NOW_SQL}, ${NOW_SQL} WHERE ${SHARE_GATE}
ON CONFLICT DO NOTHING`

/** The listing, on the item of that identity: ?11 the loads, ?12 the quantity, ?13 the notes. */
const INSERT_LISTING = `INSERT INTO gym_equipment (id, gym_id, item_id, visibility, photo_path, loads, quantity, notes,
    added_by, status, confirm_count, client_updated_at, created_at, updated_at)
SELECT ?2, ?3, (SELECT id FROM equipment_items WHERE kind_id = ?4 AND coalesce(brand_key, '') = coalesce(?8, '')
    AND coalesce(model_key, '') = coalesce(?9, '')),
  'public', ?6, ?11, ?12, ?13, ?1, 'active', 0, ${NOW_SQL}, ${NOW_SQL}, ${NOW_SQL}
WHERE ${SHARE_GATE}`

/** The gym's active listings of a kind, by authors the caller hasn't blocked: ?1 the caller, ?2 the gym, ?3 the kind. */
const DUPLICATES = `SELECT e.id, i.kind_id, i.brand, i.model, e.photo_path, e.loads, e.quantity, e.confirm_count
FROM gym_equipment e JOIN equipment_items i ON i.id = e.item_id
WHERE e.gym_id = ?2 AND e.visibility = 'public' AND e.status = 'active' AND i.kind_id = ?3 AND i.status = 'active'
  AND NOT ${blockedAuthor('e.added_by', '?1')} AND NOT ${blockedAuthor('i.created_by', '?1')}
ORDER BY e.confirm_count DESC, e.id`

/** Why a share wrote nothing: ?1 the caller, ?2 the listing id, ?3 the gym, ?4 the photo. */
const WHY_NOT = `SELECT
  EXISTS (SELECT 1 FROM gyms WHERE id = ?3 AND visibility = 'public' AND status = 'active') AS shareable,
  (?4 IS NULL OR EXISTS (SELECT 1 FROM photo_objects WHERE bucket = 'gym-photos' AND name = ?4 AND owner_id = ?1))
    AS photo_owned,
  (SELECT count(*) FROM gym_equipment WHERE visibility = 'public' AND added_by = ?1 AND created_at > ${DAY_AGO_SQL})
    AS shared_today,
  (?4 IS NOT NULL AND EXISTS (SELECT 1 FROM gym_equipment WHERE photo_path = ?4)) AS photo_used,
  (SELECT count(*) FROM gym_equipment WHERE gym_id = ?3 AND visibility = 'public' AND status = 'active'
    AND deleted_at IS NULL) AS at_gym,
  (SELECT added_by FROM gym_equipment WHERE id = ?2) AS taken_by`

interface ListingOwner {
  readonly added_by: string | null
  readonly visibility: string
}

/** A listing with this id already exists: a retry of the caller's own share, or not theirs to take over. */
function sameShareOrRefuse(listing: ListingOwner, me: string, id: string): ShareAnswer {
  if (listing.added_by !== me || listing.visibility !== 'public') throw Refusals.notAllowed()
  return { status: 'created', listing_id: id }
}

/**
 * Creates a public listing, or answers the gym's active listings of that kind when there are some and force_new is
 * false. The listing id is the phone's, so a retry after a lost answer finds the listing instead of adding another.
 * The photo must be the caller's own upload, stored and unused, so a listing can't borrow someone else's image.
 */
export async function shareListing(env: Env, me: string, input: ShareInput): Promise<ShareAnswer> {
  const db = env.DB
  const existing = await db.prepare('SELECT added_by, visibility FROM gym_equipment WHERE id = ?1')
    .bind(input.listingId).first<ListingOwner>()
  if (existing) return sameShareOrRefuse(existing, me, input.listingId)
  const gym = await db.prepare("SELECT 1 FROM gyms WHERE id = ?1 AND visibility = 'public' AND status = 'active'")
    .bind(input.gymId).first()
  if (!gym) throw Refusals.gymNotShareable()
  if (input.photoPath !== null &&
    !(await ownedStoredPhotos(env, me, SHARED_BUCKET, [input.photoPath])).has(input.photoPath)) {
    throw Refusals.photoMissing()
  }
  const loads = parseLoads(input.loads)
  if (loads === null) throw badRequest('invalid loads')
  if (!input.forceNew) {
    const { results } = await db.prepare(DUPLICATES).bind(me, input.gymId, input.kindId).all<Row>()
    if (results.length > 0) {
      return { status: 'duplicates', listings: results.map((r) => ({ ...r, loads: JSON.parse(String(r.loads)) })) }
    }
  }
  if (!(await db.prepare('SELECT 1 FROM equipment_kinds WHERE id = ?1').bind(input.kindId).first())) {
    throw badRequest('unknown kind')
  }
  const brand = trimmedOrNull(input.brand)
  const model = trimmedOrNull(input.model)
  const notes = trimmedOrNull(input.notes)
  requireCleanText(brand, 'brand')
  requireCleanText(model, 'model')
  requireCleanText(notes, 'notes', true)
  const gate = [me, input.listingId, input.gymId, input.kindId, brand, input.photoPath, model, foldKey(brand), foldKey(model)]
  const [, , written] = await db.batch([
    db.prepare(ENSURE_ITEM).bind(...gate, crypto.randomUUID()),
    db.prepare(INSERT_LISTING).bind(...gate, null, JSON.stringify(loads), input.quantity ?? 1, notes),
    db.prepare('SELECT added_by, visibility FROM gym_equipment WHERE id = ?1').bind(input.listingId),
  ])
  const listing = written.results[0] as ListingOwner | undefined
  if (listing !== undefined) return sameShareOrRefuse(listing, me, input.listingId)
  throw await whyNotShared(db, me, input)
}

/** The refusal share_listing would have raised, in its order. */
async function whyNotShared(db: D1Database, me: string, input: ShareInput): Promise<ApiError> {
  const why = (await db.prepare(WHY_NOT).bind(me, input.listingId, input.gymId, input.photoPath).first<{
    shareable: number
    photo_owned: number
    shared_today: number
    photo_used: number
    at_gym: number
    taken_by: string | null
  }>())!
  if (why.taken_by !== null) return Refusals.notAllowed()
  if (why.shareable !== 1) return Refusals.gymNotShareable()
  if (why.photo_owned !== 1) return Refusals.photoMissing()
  if (why.shared_today >= DomainLimits.dailyShares) return Refusals.dailyLimit()
  if (why.photo_used === 1) return Refusals.photoInUse()
  if (why.at_gym >= DomainLimits.gymActiveListingsMax) return Refusals.gymFull()
  return new ApiError(503, 'try_again', 'The share could not be saved. Try again.')
}

// ---- confirm_listing ----

/** A public listing that is active under an active gym and item, by an author the caller (?2) hasn't blocked. */
const CONFIRMABLE = `SELECT e.added_by, e.confirm_count FROM gym_equipment e
WHERE e.id = ?1 AND e.visibility = 'public' AND e.status = 'active'
  AND EXISTS (SELECT 1 FROM gyms g WHERE g.id = e.gym_id AND g.status = 'active')
  AND EXISTS (SELECT 1 FROM equipment_items i WHERE i.id = e.item_id AND i.status = 'active')
  AND NOT ${blockedAuthor('e.added_by', '?2')}`

const CONFIRM = `INSERT INTO equipment_confirmations (listing_id, user_id, created_at)
SELECT ?1, ?2, ${NOW_SQL}
WHERE (SELECT count(*) FROM equipment_confirmations WHERE user_id = ?2
  AND created_at > ${DAY_AGO_SQL}) < ${DomainLimits.dailyConfirmations}
ON CONFLICT DO NOTHING`

/** gym_equipment_count_confirmations, which was a trigger; updated_at moves as set_updated_at moved it. */
const RECOUNT = `UPDATE gym_equipment SET
  confirm_count = (SELECT count(*) FROM equipment_confirmations WHERE listing_id = ?1),
  updated_at = ${laterStamp('gym_equipment.updated_at', NOW_SQL)}
WHERE id = ?1 AND confirm_count <> (SELECT count(*) FROM equipment_confirmations WHERE listing_id = ?1)`

const AFTER_CONFIRM = `SELECT confirm_count,
  EXISTS (SELECT 1 FROM equipment_confirmations WHERE listing_id = ?1 AND user_id = ?2) AS confirmed
FROM gym_equipment WHERE id = ?1`

/** "Yes, that's it (+1)". Idempotent; the author's own listing already counts for them. Answers the count. */
export async function confirmListing(db: D1Database, me: string, listingId: string): Promise<number> {
  const listing = await db.prepare(CONFIRMABLE).bind(listingId, me)
    .first<{ added_by: string | null; confirm_count: number }>()
  if (!listing) throw Refusals.unknownListing()
  if (listing.added_by === me) return listing.confirm_count
  const [, , after] = await db.batch([
    db.prepare(CONFIRM).bind(listingId, me),
    db.prepare(RECOUNT).bind(listingId),
    db.prepare(AFTER_CONFIRM).bind(listingId, me),
  ])
  const row = after.results[0] as { confirm_count: number; confirmed: number }
  if (row.confirmed !== 1) throw Refusals.dailyLimit()
  return row.confirm_count
}
```

- [ ] **Step 5: Add the three routes to `server/src/gyms/routes.ts`**

Add to the imports:

```ts
import { jsonBody } from '../http/body.ts'
import { confirmListing, findOrCreateGym, parsePlace, parseShare, shareListing } from './share.ts'
```

and at the end:

```ts
catalogueRoutes.post('/gyms/find-or-create', async (c) =>
  c.json({ id: await findOrCreateGym(c.env.DB, c.var.userId, parsePlace(await jsonBody(c))) }))

catalogueRoutes.post('/listings/share', async (c) =>
  c.json(await shareListing(c.env, c.var.userId, parseShare(await jsonBody(c)))))

catalogueRoutes.post('/listings/:id/confirm', async (c) =>
  c.json({ confirm_count: await confirmListing(c.env.DB, c.var.userId, uuidOf(c.req.param('id'), 'id')) }))
```

- [ ] **Step 6: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  19 passed (19)`, `Tests  232 passed (232)`.

- [ ] **Step 7: Commit**

```bash
git add server/src server/test/gym-fixtures.ts server/test/share.test.ts
git commit -m "feat(server): find or create a gym, share and confirm listings, with their daily limits"
```

- [ ] **Step 8: Review**

Ask **code-reviewer** to compare each function line by line with `find_or_create_gym`, `ensure_equipment_item`,
`share_listing` and `confirm_listing`. Then **security-reviewer** on the limits:
- every count sits in the statement that writes;
- the item and the listing can't be written apart (one gate, one batch);
- 35 shares at once give exactly 30.

---

### Task 7: Reports, blocks and the admin queue

`POST /v1/reports`, `POST /v1/blocks`, `DELETE /v1/blocks`, `GET /v1/admin/me`, `GET /v1/admin/queue`,
`POST /v1/admin/moderate` and `POST /v1/admin/photo-deleted`. They port `report_content`, `block_author`,
`unblock_all`, `is_app_admin`, `moderation_queue`, `moderate_content` and `moderation_photo_deleted`, with the limits
of 20 reports, 20 new blocks and 3 unblock-alls a day.

**Files:**
- Create: `server/src/moderation/targets.ts`, `server/src/moderation/reports.ts`, `server/src/moderation/admin.ts`,
  `server/src/moderation/routes.ts`
- Modify: `server/src/index.ts`, `server/test/gym-fixtures.ts`
- Test: `server/test/moderation.test.ts`, `server/test/admin.test.ts`

- [ ] **Step 1: Write the fixtures and the failing tests**

Add at the end of `server/test/gym-fixtures.ts`:

```ts
/** An account with no session, as an author to block: cheaper than signing up. */
export async function insertUser(): Promise<string> {
  const id = crypto.randomUUID()
  await env.DB.prepare(
    'INSERT INTO "user" (id, name, email, "emailVerified", "createdAt", "updatedAt") VALUES (?1, ?2, ?3, 0, ?4, ?4)',
  ).bind(id, 'Fixture', `f-${id}@test.local`, T).run()
  return id
}

/** `count` reports the account filed just now, on targets nobody else reported. */
export async function reportsToday(userId: string, count: number) {
  const ids = Array.from({ length: count }, () => crypto.randomUUID())
  await env.DB.prepare(
    `INSERT INTO reports (id, target_type, target_id, reporter_id, reason, created_at)
     SELECT value, 'listing', value, ?2, 'spam', ${NOW_SQL} FROM json_each(?1)`,
  ).bind(JSON.stringify(ids), userId).run()
}

/** `count` accounts the user blocked just now. */
export async function blocksToday(userId: string, count: number): Promise<string[]> {
  const blocked = await Promise.all(Array.from({ length: count }, () => insertUser()))
  await env.DB.prepare(
    `INSERT INTO user_blocks (blocker_id, blocked_id, created_at) SELECT ?2, value, ${NOW_SQL} FROM json_each(?1)`,
  ).bind(JSON.stringify(blocked), userId).run()
  return blocked
}

/** `count` unblock-alls the account made just now. */
export async function unblocksToday(userId: string, count: number) {
  for (let i = 0; i < count; i++) {
    await env.DB.prepare(`INSERT INTO gym_unblocks (user_id, created_at) VALUES (?1, ${NOW_SQL})`).bind(userId).run()
  }
}
```

`server/test/moderation.test.ts` (from `gym_moderation.test.sql` lines 54–101, 128 and 150–217, and
`gym_review_fixes.test.sql` lines 43–75):

```ts
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import {
  agedRows, blocksToday, DAYS_AGO, genericItem, insertGym, insertListing, reportsToday, setStatus, unblocksToday,
} from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'

type Json = Record<string, any>
type Target = { target_type: string; target_id: string }

const report = (token: string, target: Target, reason = 'spam', note: unknown = null) =>
  request('POST', '/v1/reports', { token, body: { ...target, reason, note } })
const blockOf = (token: string, target: Target) => request('POST', '/v1/blocks', { token, body: target })
const unblockAll = (token: string) => request('DELETE', '/v1/blocks', { token })

async function answer(res: Response, status = 200): Promise<Json> {
  expect(res.status).toBe(status)
  return res.json<Json>()
}

const refusalOf = async (res: Response, status = 422) =>
  (await answer(res, status)).error as { code: string; message: string }

/** A public gym with one active listing by `author`. */
async function shared(author: string) {
  const gym = await insertGym({ visibility: 'public', createdBy: author })
  const listing = await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: author })
  return { gym, listing, target: { target_type: 'listing', target_id: listing } }
}

const statusOf = async (table: 'gyms' | 'gym_equipment', id: string) =>
  (await env.DB.prepare(`SELECT status FROM ${table} WHERE id = ?1`).bind(id).first<{ status: string }>())!.status
const count = async (sql: string, ...bindings: unknown[]) =>
  (await env.DB.prepare(sql).bind(...bindings).first<{ n: number }>())!.n
const listingsSeenBy = async (token: string, gym: string) =>
  (await answer(await request('GET', `/v1/gyms/${gym}/listings`, { token }))).rows as Json[]

describe('reports', () => {
  it('store a report with its note trimmed, and answer already to the same account again, whatever it sends',
    async () => {
      const author = await signUp()
      const b = await signUp()
      const { listing, target } = await shared(author.userId)
      expect(await answer(await report(b.token, target, 'person-in-photo', '  a face  '))).toEqual({ status: 'reported' })
      const stored = await env.DB.prepare('SELECT reason, note, reporter_id FROM reports WHERE target_id = ?1')
        .bind(listing).first()
      expect(stored).toEqual({ reason: 'person-in-photo', note: 'a face', reporter_id: b.userId })
      expect(await answer(await report(b.token, target))).toEqual({ status: 'already' })
      expect(await answer(await report(b.token, target, 'not-a-reason'))).toEqual({ status: 'already' })
    })

  it('answer own to an author reporting their own content, and store nothing', async () => {
    const author = await signUp()
    const { listing, target } = await shared(author.userId)
    expect(await answer(await report(author.token, target))).toEqual({ status: 'own' })
    expect(await count('SELECT count(*) AS n FROM reports WHERE target_id = ?1', listing)).toBe(0)
  })

  it('refuse a target that is not a public gym or listing, or was removed', async () => {
    const author = await signUp()
    const b = await signUp()
    const { listing } = await shared(author.userId)
    const privateGym = await insertGym({ visibility: 'private', owner: author.userId })
    const removed = await shared(author.userId)
    await setStatus('gym_equipment', removed.listing, 'removed')
    const targets = [
      { target_type: 'item', target_id: await genericItem() }, { target_type: 'nonsense', target_id: listing },
      { target_type: 'listing', target_id: crypto.randomUUID() }, { target_type: 'gym', target_id: privateGym },
      removed.target,
    ]
    for (const target of targets) {
      expect(await refusalOf(await report(b.token, target))).toEqual({ code: 'unknown_target', message: 'unknown target' })
    }
    expect((await refusalOf(await report(b.token, { target_type: 'listing', target_id: 'nope' }), 400)).code)
      .toBe('bad_request')
  })

  it('refuse a reason that is not on the list, and a note that is too long or has hidden characters', async () => {
    const author = await signUp()
    const b = await signUp()
    const refused: [string, string | null][] = [['not-a-reason', null], ['other', 'x'.repeat(281)], ['other', 'look\u{E0041}']]
    for (const [reason, note] of refused) {
      const { target } = await shared(author.userId)
      expect((await refusalOf(await report(b.token, target, reason, note))).code).toBe('row_rejected')
    }
    const { target } = await shared(author.userId)
    expect(await answer(await report(b.token, target, 'other', 'two\nlines'))).toEqual({ status: 'reported' })
  })

  it('flag a target at three reports from three accounts, hiding it from everyone but its author', async () => {
    const author = await signUp()
    const viewer = await signUp()
    const { gym, listing, target } = await shared(author.userId)
    for (let i = 0; i < 2; i++) await answer(await report((await signUp()).token, target))
    expect(await statusOf('gym_equipment', listing)).toBe('active')
    expect(await listingsSeenBy(viewer.token, gym)).toHaveLength(1)
    await answer(await report((await signUp()).token, target))
    expect(await statusOf('gym_equipment', listing)).toBe('flagged')
    expect(await listingsSeenBy(viewer.token, gym)).toEqual([])
    expect((await listingsSeenBy(author.token, gym))[0]).toMatchObject({ id: listing, status: 'flagged' })
  })

  it("don't flag a target whose reporters closed their accounts in between", async () => {
    const author = await signUp()
    const { listing, target } = await shared(author.userId)
    for (let i = 0; i < 3; i++) {
      const reporter = await signUp()
      await answer(await report(reporter.token, target))
      expect((await request('DELETE', '/v1/account', { token: reporter.token })).status).toBe(204)
    }
    expect(await statusOf('gym_equipment', listing)).toBe('active')
    expect(await count('SELECT count(*) AS n FROM reports WHERE target_id = ?1 AND reporter_id IS NULL', listing)).toBe(3)
  })

  it('take 20 a day; the 21st is refused, and older reports do not count', async () => {
    const author = await signUp()
    const b = await signUp()
    await reportsToday(b.userId, 19)
    await answer(await report(b.token, (await shared(author.userId)).target))
    expect(await refusalOf(await report(b.token, (await shared(author.userId)).target))).toEqual({
      code: 'daily_limit', message: "You've shared a lot today. Try again tomorrow.",
    })
    await agedRows('reports', 'reporter_id', b.userId)
    await answer(await report(b.token, (await shared(author.userId)).target))
  })
})

describe('blocks', () => {
  it('hide everything by a blocked author, and unblocking all brings it back', async () => {
    const author = await signUp()
    const b = await signUp()
    const first = await shared(author.userId)
    const second = await shared(author.userId)
    expect((await blockOf(b.token, first.target)).status).toBe(204)
    expect(await listingsSeenBy(b.token, second.gym)).toEqual([])
    expect(await answer(await unblockAll(b.token))).toEqual({ cleared: 1 })
    expect(await listingsSeenBy(b.token, second.gym)).toHaveLength(1)
  })

  it('do nothing for your own content, a gym with no author, or an author already blocked', async () => {
    const author = await signUp()
    const { target } = await shared(author.userId)
    expect((await blockOf(author.token, target)).status).toBe(204)
    expect(await count('SELECT count(*) AS n FROM user_blocks WHERE blocker_id = ?1', author.userId)).toBe(0)
    const b = await signUp()
    const orphan = await insertGym({ visibility: 'public' })
    expect((await blockOf(b.token, { target_type: 'gym', target_id: orphan })).status).toBe(204)
    expect((await blockOf(b.token, target)).status).toBe(204)
    expect((await blockOf(b.token, target)).status).toBe(204)
    expect(await count('SELECT count(*) AS n FROM user_blocks WHERE blocker_id = ?1', b.userId)).toBe(1)
    const unknown = await blockOf(b.token, { target_type: 'listing', target_id: crypto.randomUUID() })
    expect((await refusalOf(unknown)).code).toBe('unknown_target')
  })

  it('take 20 new blocks a day; the 21st is refused, a repeat still succeeds, and an older block frees a slot',
    async () => {
      const b = await signUp()
      const earlier = await blocksToday(b.userId, 19)
      const twentieth = await shared((await signUp()).userId)
      expect((await blockOf(b.token, twentieth.target)).status).toBe(204)
      const next = await shared((await signUp()).userId)
      expect((await refusalOf(await blockOf(b.token, next.target))).code).toBe('daily_limit')
      expect((await blockOf(b.token, twentieth.target)).status).toBe(204)
      expect(await count('SELECT count(*) AS n FROM user_blocks WHERE blocker_id = ?1', b.userId)).toBe(20)
      await env.DB.prepare('UPDATE user_blocks SET created_at = ?3 WHERE blocker_id = ?1 AND blocked_id = ?2')
        .bind(b.userId, earlier[0], DAYS_AGO).run()
      expect((await blockOf(b.token, next.target)).status).toBe(204)
    })
})

describe('unblocking all', () => {
  it('clears 3 times a day; the 4th is refused even with nothing to clear, and the blocks stay', async () => {
    const b = await signUp()
    for (let i = 0; i < 3; i++) {
      await blocksToday(b.userId, 1)
      expect(await answer(await unblockAll(b.token))).toEqual({ cleared: 1 })
    }
    await blocksToday(b.userId, 1)
    expect((await refusalOf(await unblockAll(b.token))).code).toBe('daily_limit')
    expect(await count('SELECT count(*) AS n FROM user_blocks WHERE blocker_id = ?1', b.userId)).toBe(1)
    await env.DB.prepare('DELETE FROM user_blocks WHERE blocker_id = ?1').bind(b.userId).run()
    expect((await refusalOf(await unblockAll(b.token))).code).toBe('daily_limit')
  })

  it("logs only clears that cleared something, and counts only the last day's", async () => {
    const b = await signUp()
    expect(await answer(await unblockAll(b.token))).toEqual({ cleared: 0 })
    expect(await count('SELECT count(*) AS n FROM gym_unblocks WHERE user_id = ?1', b.userId)).toBe(0)
    await unblocksToday(b.userId, 3)
    await blocksToday(b.userId, 2)
    expect((await refusalOf(await unblockAll(b.token))).code).toBe('daily_limit')
    await agedRows('gym_unblocks', 'user_id', b.userId)
    expect(await answer(await unblockAll(b.token))).toEqual({ cleared: 2 })
  })
})
```

`server/test/admin.test.ts` (from `gym_moderation.test.sql` lines 105–137, 174–209, and `gym_review_fixes.test.sql`
lines 89–168):

```ts
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { insertGym, makeAdmin, setStatus, uploadedPhoto } from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'

type Json = Record<string, any>
type Account = { token: string; userId: string }

async function answer(res: Response, status = 200): Promise<Json> {
  expect(res.status).toBe(status)
  return res.json<Json>()
}

const refusalOf = async (res: Response, status = 422) =>
  (await answer(res, status)).error as { code: string; message: string }

async function admin(): Promise<Account> {
  const account = await signUp()
  await makeAdmin(account.userId)
  return account
}

const queueFor = async (token: string, ids: string[]) =>
  ((await answer(await request('GET', '/v1/admin/queue', { token }))).rows as Json[]).filter((r) => ids.includes(r.target_id))
const moderate = (token: string, target_type: string, target_id: string, action: string) =>
  request('POST', '/v1/admin/moderate', { token, body: { target_type, target_id, action } })
const report = (token: string, target_type: string, target_id: string, reason = 'spam', note: string | null = null) =>
  request('POST', '/v1/reports', { token, body: { target_type, target_id, reason, note } })
const photoDeleted = (token: string, path: string) => request('POST', '/v1/admin/photo-deleted', { token, body: { path } })
const photoOf = async (listing: string) =>
  env.DB.prepare('SELECT photo_path FROM gym_equipment WHERE id = ?1').bind(listing).first()

/** "Review Gym, 1 Main St", made through the app's routes, with one shared listing. */
async function reviewGym(author: Account, listing: Json = {}) {
  const place = `place-${crypto.randomUUID()}`
  const created = await request('POST', '/v1/gyms/find-or-create', {
    token: author.token, body: { maps_place_id: place, name: 'Review Gym', address: '1 Main St' },
  })
  const gym = (await answer(created)).id as string
  const body = {
    listing_id: crypto.randomUUID(), gym_id: gym, kind_id: 'dumbbells', loads: { type: 'none' }, force_new: true,
    ...listing,
  }
  const shared = await answer(await request('POST', '/v1/listings/share', { token: author.token, body }))
  return { gym, place, listing: shared.listing_id as string }
}

describe('admins', () => {
  it('are told so, and nobody else is', async () => {
    const a = await signUp()
    expect(await answer(await request('GET', '/v1/admin/me', { token: a.token }))).toEqual({ admin: false })
    await makeAdmin(a.userId)
    expect(await answer(await request('GET', '/v1/admin/me', { token: a.token }))).toEqual({ admin: true })
  })

  it('alone read the queue, moderate and confirm a deleted photo', async () => {
    const a = await signUp()
    const { listing } = await reviewGym(a)
    const answers = [
      await request('GET', '/v1/admin/queue', { token: a.token }),
      await moderate(a.token, 'listing', listing, 'remove'),
      await moderate(a.token, 'item', listing, 'nuke'),
      await photoDeleted(a.token, `${crypto.randomUUID()}.jpg`),
    ]
    for (const res of answers) expect(await refusalOf(res, 403)).toEqual({ code: 'not_allowed', message: 'Not allowed.' })
  })
})

describe('the moderation queue', () => {
  it('lists open reports flagged first, then the most reported, a single report included', async () => {
    const author = await signUp()
    const boss = await admin()
    const { gym, listing: listed } = await reviewGym(author, { notes: 'text me 555' })
    const { listing: branded } = await reviewGym(author, { brand: 'Acme', model: 'X1' })
    for (let i = 0; i < 3; i++) await answer(await report((await signUp()).token, 'listing', listed))
    for (let i = 0; i < 2; i++) await answer(await report((await signUp()).token, 'gym', gym, 'wrong-info'))
    await answer(await report((await signUp()).token, 'listing', branded, 'person-in-photo', 'a face'))
    expect(await queueFor(boss.token, [gym, listed, branded])).toEqual([
      {
        target_type: 'listing', target_id: listed, title: 'Dumbbells', photo_path: null, report_count: 3,
        reasons: { spam: 3 }, notes: [], status: 'flagged', address: 'Review Gym, 1 Main St', listing_notes: 'text me 555',
      },
      {
        target_type: 'gym', target_id: gym, title: 'Review Gym', photo_path: null, report_count: 2,
        reasons: { 'wrong-info': 2 }, notes: [], status: 'active', address: '1 Main St', listing_notes: null,
      },
      {
        target_type: 'listing', target_id: branded, title: 'Acme X1', photo_path: null, report_count: 1,
        reasons: { 'person-in-photo': 1 }, notes: ['a face'], status: 'active', address: 'Review Gym, 1 Main St',
        listing_notes: null,
      },
    ])
  })

  it('counts each reason, keeps the notes in the order they were filed, and never says who reported', async () => {
    const author = await signUp()
    const boss = await admin()
    const { listing } = await reviewGym(author)
    await answer(await report((await signUp()).token, 'listing', listing, 'person-in-photo', 'a face'))
    await answer(await report((await signUp()).token, 'listing', listing, 'spam'))
    await answer(await report((await signUp()).token, 'listing', listing, 'other', 'wrong gym'))
    const [row] = await queueFor(boss.token, [listing])
    expect(row).toMatchObject({
      report_count: 3, reasons: { 'person-in-photo': 1, spam: 1, other: 1 }, notes: ['a face', 'wrong gym'],
      status: 'flagged',
    })
    for (const column of ['reporter_id', 'reporters', 'created_by', 'added_by']) expect(row).not.toHaveProperty(column)
  })

  it('keeps a flagged gym with no open reports, with nothing counted', async () => {
    const boss = await admin()
    const gym = await insertGym({ visibility: 'public', status: 'flagged' })
    expect(await queueFor(boss.token, [gym])).toMatchObject([
      { target_type: 'gym', report_count: 0, reasons: {}, notes: [], status: 'flagged' },
    ])
  })

  it("counts the reports of accounts that closed since, which can't flag", async () => {
    const author = await signUp()
    const boss = await admin()
    const { listing } = await reviewGym(author)
    for (let i = 0; i < 3; i++) {
      const reporter = await signUp()
      await answer(await report(reporter.token, 'listing', listing))
      expect((await request('DELETE', '/v1/account', { token: reporter.token })).status).toBe(204)
    }
    expect(await queueFor(boss.token, [listing])).toMatchObject([{ report_count: 3, status: 'active' }])
  })
})

describe('moderating', () => {
  it('restores a target and resolves its reports: it leaves the queue, and a reporter hears already', async () => {
    const author = await signUp()
    const viewer = await signUp()
    const boss = await admin()
    const { gym, listing } = await reviewGym(author)
    const reporters = [await signUp(), await signUp(), await signUp()]
    for (const reporter of reporters) await answer(await report(reporter.token, 'listing', listing))
    expect(await answer(await moderate(boss.token, 'listing', listing, 'restore'))).toEqual({ status: 'active', photo_path: null })
    expect(await queueFor(boss.token, [listing])).toEqual([])
    expect((await answer(await request('GET', `/v1/gyms/${gym}/listings`, { token: viewer.token }))).rows).toHaveLength(1)
    expect(await answer(await report(reporters[0].token, 'listing', listing))).toEqual({ status: 'already' })
  })

  it('removes a listing and answers its photo; the name stays until the photo is deleted, and a retry answers it',
    async () => {
      const author = await signUp()
      const boss = await admin()
      const photo = await uploadedPhoto(author.userId, 'gym-photos')
      const { gym, listing } = await reviewGym(author, { photo_path: photo })
      const removed = { status: 'removed', photo_path: photo }
      expect(await answer(await moderate(boss.token, 'listing', listing, 'remove'))).toEqual(removed)
      expect(await answer(await moderate(boss.token, 'listing', listing, 'remove'))).toEqual(removed)
      expect(await queueFor(boss.token, [listing])).toMatchObject([{ status: 'removed', photo_path: photo }])
      const reuse = {
        listing_id: crypto.randomUUID(), gym_id: gym, kind_id: 'dumbbells', loads: { type: 'none' }, photo_path: photo,
        force_new: true,
      }
      const again = await request('POST', '/v1/listings/share', { token: author.token, body: reuse })
      expect((await refusalOf(again)).code).toBe('photo_in_use')
      expect((await photoDeleted(boss.token, photo)).status).toBe(204)
      expect(await photoOf(listing)).toEqual({ photo_path: null })
      expect(await queueFor(boss.token, [listing])).toEqual([])
      expect(await answer(await moderate(boss.token, 'listing', listing, 'restore'))).toEqual({ status: 'active', photo_path: null })
    })

  it('photo-deleted leaves a name that is unknown, or on a listing that was not removed', async () => {
    const author = await signUp()
    const boss = await admin()
    const photo = await uploadedPhoto(author.userId, 'gym-photos')
    const { listing } = await reviewGym(author, { photo_path: photo })
    for (const path of [`${crypto.randomUUID()}.jpg`, photo]) expect((await photoDeleted(boss.token, path)).status).toBe(204)
    expect(await photoOf(listing)).toEqual({ photo_path: photo })
  })

  it('refuses an unknown action, and restoring a gym whose place another gym has taken', async () => {
    const author = await signUp()
    const boss = await admin()
    const { gym, place } = await reviewGym(author)
    expect(await refusalOf(await moderate(boss.token, 'gym', gym, 'nuke'), 400))
      .toEqual({ code: 'bad_request', message: 'invalid action' })
    expect(await answer(await moderate(boss.token, 'gym', gym, 'remove'))).toEqual({ status: 'removed', photo_path: null })
    const created = await request('POST', '/v1/gyms/find-or-create', {
      token: author.token, body: { maps_place_id: place, name: 'New Gym' },
    })
    const newer = (await answer(created)).id as string
    expect(newer).not.toBe(gym)
    expect(await refusalOf(await moderate(boss.token, 'gym', gym, 'restore'))).toEqual({
      code: 'place_taken', message: 'Another gym now has this place.',
    })
    await setStatus('gyms', newer, 'removed')
    expect(await answer(await moderate(boss.token, 'gym', gym, 'restore'))).toEqual({ status: 'active', photo_path: null })
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/moderation.test.ts test/admin.test.ts`
Expected: FAIL, with `404 not_found` from every route.

- [ ] **Step 3: Write `server/src/moderation/targets.ts`**

```ts
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
```

- [ ] **Step 4: Write `server/src/moderation/reports.ts`**

```ts
import { Refusals } from '../gyms/refusals.ts'
import { requireCleanText, trimmedOrNull } from '../gyms/text.ts'
import { badRequest, textOrNull } from '../http/input.ts'
import { DomainLimits } from '../shared/domain-limits.ts'
import { DAY_AGO_SQL, laterStamp, NOW_SQL } from '../sync/time.ts'
import { publicTarget, type Target, TARGET_TABLE } from './targets.ts'

// report_content, block_author and unblock_all (supabase/migrations/20261030000006_gym_moderation.sql). Each daily
// limit sits in the one batch that writes.

/** Unresolved reports from this many existing accounts hide a target until an admin decides. */
export const FLAG_REPORTS = 3

const FILE_REPORT = `INSERT INTO reports (id, target_type, target_id, reporter_id, reason, note, created_at)
SELECT ?1, ?2, ?3, ?4, ?5, ?6, ${NOW_SQL}
WHERE (SELECT count(*) FROM reports WHERE reporter_id = ?4 AND created_at > ${DAY_AGO_SQL}) < ${DomainLimits.dailyReports}
ON CONFLICT DO NOTHING`

/**
 * Flags an active target once enough accounts reported it. A report whose author has since deleted their account
 * (reporter_id is null) doesn't count, or a loop of sign up, report, delete would reach three alone; it stays for the
 * queue. ?1 the target, ?2 its type.
 */
const flagSql = (table: string) => `UPDATE ${table} SET status = 'flagged',
  updated_at = ${laterStamp(`${table}.updated_at`, NOW_SQL)}
WHERE id = ?1 AND status = 'active' AND (SELECT count(*) FROM reports WHERE target_type = ?2 AND target_id = ?1
  AND resolved_at IS NULL AND reporter_id IS NOT NULL) >= ${FLAG_REPORTS}`

const MY_REPORT = 'SELECT 1 FROM reports WHERE target_type = ?1 AND target_id = ?2 AND reporter_id = ?3'

export type ReportAnswer = { readonly status: 'reported' | 'own' | 'already' }

/** One report per account per target; your own content answers `own`, a second report `already`. */
export async function reportContent(
  db: D1Database,
  me: string,
  target: Target,
  reason: unknown,
  rawNote: unknown,
): Promise<ReportAnswer> {
  const { author, status } = await publicTarget(db, target)
  if (status === 'removed') throw Refusals.unknownTarget()
  if (author === me) return { status: 'own' }
  if (await db.prepare(MY_REPORT).bind(target.type, target.id, me).first()) return { status: 'already' }
  if (typeof reason !== 'string') throw badRequest('reason must be text.')
  const note = trimmedOrNull(textOrNull(rawNote, 'note'))
  requireCleanText(note, 'note', true)
  const [, , mine] = await db.batch([
    db.prepare(FILE_REPORT).bind(crypto.randomUUID(), target.type, target.id, me, reason, note),
    db.prepare(flagSql(TARGET_TABLE[target.type])).bind(target.id, target.type),
    db.prepare(MY_REPORT).bind(target.type, target.id, me),
  ])
  if (mine.results.length === 0) throw Refusals.dailyLimit()
  return { status: 'reported' }
}

const BLOCK = `INSERT INTO user_blocks (blocker_id, blocked_id, created_at)
SELECT ?1, ?2, ${NOW_SQL}
WHERE (SELECT count(*) FROM user_blocks WHERE blocker_id = ?1 AND created_at > ${DAY_AGO_SQL}) < ${DomainLimits.dailyBlocks}
ON CONFLICT DO NOTHING`

/**
 * Blocks the author of a target. Blocking tells a script whether two rows share an author, so the daily limit is the
 * control; blocking someone already blocked is a no-op that doesn't count, so a retry always works.
 */
export async function blockAuthor(db: D1Database, me: string, target: Target): Promise<void> {
  const { author } = await publicTarget(db, target)
  if (author === null || author === me) return
  const [, blocked] = await db.batch([
    db.prepare(BLOCK).bind(me, author),
    db.prepare('SELECT 1 FROM user_blocks WHERE blocker_id = ?1 AND blocked_id = ?2').bind(me, author),
  ])
  if (blocked.results.length === 0) throw Refusals.dailyLimit()
}

const UNBLOCK = `DELETE FROM user_blocks WHERE blocker_id = ?1
  AND (SELECT count(*) FROM gym_unblocks WHERE user_id = ?1 AND created_at > ${DAY_AGO_SQL}) < ${DomainLimits.dailyUnblocks}
RETURNING blocked_id`

/** Logged only when the DELETE before it cleared something: changes() counts the batch's previous statement. */
const LOG_UNBLOCK = `INSERT INTO gym_unblocks (user_id, created_at) SELECT ?1, ${NOW_SQL} WHERE changes() > 0`

const UNBLOCKS_TODAY = `SELECT count(*) AS n FROM gym_unblocks WHERE user_id = ?1 AND created_at > ${DAY_AGO_SQL}`

/**
 * Clears every block the caller made; answers how many. Unblocking is the other half of the block probe, so each
 * clearing is logged and counted: 3 a day, refused even when there is nothing to clear, as unblock_all was.
 */
export async function unblockAll(db: D1Database, me: string): Promise<number> {
  const [cleared] = await db.batch([db.prepare(UNBLOCK).bind(me), db.prepare(LOG_UNBLOCK).bind(me)])
  if (cleared.results.length > 0) return cleared.results.length
  const used = (await db.prepare(UNBLOCKS_TODAY).bind(me).first<{ n: number }>())!.n
  if (used >= DomainLimits.dailyUnblocks) throw Refusals.dailyLimit()
  return 0
}
```

- [ ] **Step 5: Write `server/src/moderation/admin.ts`**

```ts
import { Refusals } from '../gyms/refusals.ts'
import { badRequest } from '../http/input.ts'
import { laterStamp, NOW_SQL } from '../sync/time.ts'
import { publicTarget, TARGET_TABLE, targetOf } from './targets.ts'

// is_app_admin, moderation_queue, moderate_content and moderation_photo_deleted. Admins are app_admins rows; Claude's
// tokens never reach /v1, so it is never an admin.

export async function isAdmin(db: D1Database, me: string): Promise<boolean> {
  return (await db.prepare('SELECT 1 FROM app_admins WHERE user_id = ?1').bind(me).first()) !== null
}

async function requireAdmin(db: D1Database, me: string): Promise<void> {
  if (!(await isAdmin(db, me))) throw Refusals.notAllowed()
}

export interface QueueRow {
  readonly target_type: 'gym' | 'listing'
  readonly target_id: string
  readonly title: string
  readonly photo_path: string | null
  readonly report_count: number
  readonly reasons: Readonly<Record<string, number>>
  readonly notes: readonly string[]
  readonly status: string
  readonly address: string | null
  readonly listing_notes: string | null
}

/**
 * Every public target with an unresolved report, and every flagged one even when its reports are gone; and removed
 * listings whose photo is still named, so a failed delete can be retried. `address` and `listing_notes` are the
 * target's own words, to judge it by.
 */
const QUEUE_TARGETS = `SELECT 'gym' AS target_type, g.id AS target_id, g.name AS title, NULL AS photo_path, g.status,
  g.address, NULL AS listing_notes
FROM gyms g
WHERE g.visibility = 'public' AND g.status <> 'removed'
  AND (g.status = 'flagged' OR g.id IN (SELECT r.target_id FROM reports r
    WHERE r.target_type = 'gym' AND r.resolved_at IS NULL))
UNION ALL
SELECT 'listing', e.id, coalesce(nullif(concat_ws(' ', i.brand, i.model), ''), k.name), e.photo_path, e.status,
  concat_ws(', ', g.name, g.address), e.notes
FROM gym_equipment e JOIN gyms g ON g.id = e.gym_id JOIN equipment_items i ON i.id = e.item_id
  JOIN equipment_kinds k ON k.id = i.kind_id
WHERE e.visibility = 'public'
  AND ((e.status <> 'removed' AND (e.status = 'flagged' OR e.id IN (SELECT r.target_id FROM reports r
      WHERE r.target_type = 'listing' AND r.resolved_at IS NULL)))
    OR (e.status = 'removed' AND e.photo_path IS NOT NULL))`

/** Every unresolved report, in the order filed (rowid breaks a tie within one millisecond). Never who filed it. */
const OPEN_REPORTS = `SELECT target_type, target_id, reason, note FROM reports WHERE resolved_at IS NULL
ORDER BY created_at, rowid`

type QueueTarget = Omit<QueueRow, 'report_count' | 'reasons' | 'notes'>

/** Flagged first, then the most reported, then by id. */
const queueOrder = (a: QueueRow, b: QueueRow) =>
  Number(b.status === 'flagged') - Number(a.status === 'flagged') || b.report_count - a.report_count ||
  (a.target_id < b.target_id ? -1 : a.target_id > b.target_id ? 1 : 0)

export async function moderationQueue(db: D1Database, me: string): Promise<QueueRow[]> {
  await requireAdmin(db, me)
  const [targets, reports] = await db.batch<Record<string, unknown>>([
    db.prepare(QUEUE_TARGETS), db.prepare(OPEN_REPORTS),
  ])
  const open = new Map<string, { reason: string; note: string | null }[]>()
  for (const r of reports.results) {
    const key = `${r.target_type}:${r.target_id}`
    open.set(key, [...(open.get(key) ?? []), { reason: String(r.reason), note: r.note as string | null }])
  }
  return targets.results.map((raw): QueueRow => {
    const target = raw as unknown as QueueTarget
    const filed = open.get(`${target.target_type}:${target.target_id}`) ?? []
    const reasons: Record<string, number> = {}
    for (const { reason } of filed) reasons[reason] = (reasons[reason] ?? 0) + 1
    const notes = filed.flatMap(({ note }) => (note === null ? [] : [note]))
    return { ...target, report_count: filed.length, reasons, notes }
  }).sort(queueOrder)
}

export interface Moderation {
  readonly status: 'active' | 'removed'
  readonly photo_path: string | null
}

const ACTIONS = { restore: 'active', remove: 'removed' } as const

/**
 * Restores or removes a target and resolves its reports. Removing a listing keeps its photo_path and answers it, for
 * the app to delete the photo; the name stays until photo-deleted, so a failed delete leaves something to retry and
 * the name can't be reused meanwhile. Removing a gym keeps its listings' photos. Restoring a gym whose place another
 * gym has taken since answers place_taken.
 */
export async function moderate(db: D1Database, me: string, body: Record<string, unknown>): Promise<Moderation> {
  await requireAdmin(db, me)
  const action = body.action
  if (action !== 'restore' && action !== 'remove') throw badRequest('invalid action')
  const target = targetOf(body)
  const next = ACTIONS[action]
  const { status } = await publicTarget(db, target)
  let photo: string | null = null
  if (target.type === 'listing' && action === 'remove') {
    photo = (await db.prepare('SELECT photo_path FROM gym_equipment WHERE id = ?1').bind(target.id)
      .first<{ photo_path: string | null }>())!.photo_path
    if (status === 'removed') return { status: 'removed', photo_path: photo }
  }
  const table = TARGET_TABLE[target.type]
  try {
    await db.batch([
      db.prepare(`UPDATE ${table} SET status = ?2, updated_at = ${laterStamp(`${table}.updated_at`, NOW_SQL)} WHERE id = ?1`)
        .bind(target.id, next),
      db.prepare(`UPDATE reports SET resolved_at = ${NOW_SQL} WHERE target_type = ?1 AND target_id = ?2 AND resolved_at IS NULL`)
        .bind(target.type, target.id),
    ])
  } catch (error) {
    if (target.type === 'gym' && /UNIQUE constraint failed/.test(String(error))) throw Refusals.placeTaken()
    throw error
  }
  return { status: next, photo_path: photo }
}

/** The app deleted a removed listing's photo: the listing lets go of its name. */
export async function moderationPhotoDeleted(db: D1Database, me: string, body: Record<string, unknown>): Promise<void> {
  await requireAdmin(db, me)
  if (typeof body.path !== 'string') throw badRequest('path must be text.')
  await db.prepare(
    `UPDATE gym_equipment SET photo_path = NULL, updated_at = ${laterStamp('gym_equipment.updated_at', NOW_SQL)}
     WHERE photo_path = ?1 AND status = 'removed' AND visibility = 'public'`,
  ).bind(body.path).run()
}
```

- [ ] **Step 6: Write `server/src/moderation/routes.ts` and mount it**

```ts
import { Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { jsonBody } from '../http/body.ts'
import { objectBody } from '../http/input.ts'
import { isAdmin, moderate, moderationPhotoDeleted, moderationQueue } from './admin.ts'
import { blockAuthor, reportContent, unblockAll } from './reports.ts'
import { targetOf } from './targets.ts'

/** /v1/reports, /v1/blocks and /v1/admin (spec section 3, "Moderation"). */
export const moderationRoutes = new Hono<AppEnv>()

moderationRoutes.post('/reports', async (c) => {
  const body = objectBody(await jsonBody(c))
  return c.json(await reportContent(c.env.DB, c.var.userId, targetOf(body), body.reason, body.note))
})

moderationRoutes.post('/blocks', async (c) => {
  await blockAuthor(c.env.DB, c.var.userId, targetOf(objectBody(await jsonBody(c))))
  return c.body(null, 204)
})

moderationRoutes.delete('/blocks', async (c) => c.json({ cleared: await unblockAll(c.env.DB, c.var.userId) }))

moderationRoutes.get('/admin/me', async (c) => c.json({ admin: await isAdmin(c.env.DB, c.var.userId) }))

moderationRoutes.get('/admin/queue', async (c) => c.json({ rows: await moderationQueue(c.env.DB, c.var.userId) }))

moderationRoutes.post('/admin/moderate', async (c) =>
  c.json(await moderate(c.env.DB, c.var.userId, objectBody(await jsonBody(c)))))

moderationRoutes.post('/admin/photo-deleted', async (c) => {
  await moderationPhotoDeleted(c.env.DB, c.var.userId, objectBody(await jsonBody(c)))
  return c.body(null, 204)
})
```

In `server/src/index.ts`, import it and mount it after the catalogue:

```ts
import { moderationRoutes } from './moderation/routes.ts'
```

```ts
v1.route('/', moderationRoutes)
```

- [ ] **Step 7: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  21 passed (21)`, `Tests  254 passed (254)`.

- [ ] **Step 8: Commit**

```bash
git add server/src/moderation server/src/index.ts server/test/gym-fixtures.ts server/test/moderation.test.ts \
  server/test/admin.test.ts
git commit -m "feat(server): reports, blocks and the admin queue"
```

- [ ] **Step 9: Review**

Ask **code-reviewer** to compare each function with its Postgres original. Then **security-reviewer**:
- the admin routes check `app_admins` before reading the body;
- the queue never names a reporter;
- a block can't be used to learn an author's id;
- the three daily limits hold when requests arrive together (Task 10 adds those tests).

---

### Task 8: Gym photos: upload, read, delete, list, detach

`PUT`, `GET` and `DELETE /v1/photos/private/:name`; `PUT` and `DELETE /v1/photos/shared/:name`; `GET /v1/photos/mine`;
`POST /v1/photos/detach`. Together they replace Storage, the bucket policies, `guard_gym_photo`, `my_gym_photos` and
`detach_my_gym_photos`, with the limit of 60 uploads a day across both buckets.

**Files:**
- Create: `server/src/photos/store.ts`, `server/src/photos/routes.ts`
- Modify: `server/src/index.ts`, `server/test/helpers.ts`, `server/test/gym-fixtures.ts`
- Test: `server/test/photos.test.ts`

- [ ] **Step 1: Write the helpers and the failing tests**

Add at the end of `server/test/helpers.ts`:

```ts
/** A photo upload as the app sends it: the raw bytes with their content type. */
export function upload(token: string, path: string, bytes: Uint8Array, contentType = 'image/jpeg'): Promise<Response> {
  const headers = { authorization: `Bearer ${token}`, 'content-type': contentType }
  return Promise.resolve(app.fetch(new Request(`${ORIGIN}${path}`, { method: 'PUT', headers, body: bytes }), env))
}
```

Add at the end of `server/test/gym-fixtures.ts`:

```ts
/** `count` photos the account uploaded just now (rows only), towards the daily limit. */
export async function photosToday(owner: string, count: number, bucket: 'gym-photos' | 'gym-photos-private') {
  const names = Array.from({ length: count }, () => `${crypto.randomUUID()}.jpg`)
  await env.DB.prepare(
    `INSERT INTO photo_objects (bucket, name, owner_id, created_at) SELECT ?2, value, ?3, ${NOW_SQL} FROM json_each(?1)`,
  ).bind(JSON.stringify(names), bucket, owner).run()
  return names
}
```

`server/test/photos.test.ts` (from `gym_photo_guard.test.sql`, `gyms.test.sql` lines 306–332, `gym_review_fixes.test.sql`
lines 100–122 and 198–211, and `gym_moderation.test.sql` lines 222–242):

```ts
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { PRIVATE_BUCKET } from '../src/photos/objects.ts'
import { uploadPhoto } from '../src/photos/store.ts'
import {
  agedRows, genericItem, insertGym, insertListing, JPEG, makeAdmin, photosToday, setStatus, uploadedPhoto,
} from './gym-fixtures.ts'
import { request, signUp, upload } from './helpers.ts'

type Json = Record<string, any>

const photo = () => `${crypto.randomUUID()}.jpg`
const privatePath = (name: string) => `/v1/photos/private/${name}`
const sharedPath = (name: string) => `/v1/photos/shared/${name}`

async function refusalOf(res: Response, status = 422) {
  expect(res.status).toBe(status)
  return (await res.json<{ error: { code: string; message: string } }>()).error
}

const rowsOf = async (name: string) =>
  (await env.DB.prepare('SELECT count(*) AS n FROM photo_objects WHERE name = ?1').bind(name).first<{ n: number }>())!.n
const mine = async (token: string) => (await (await request('GET', '/v1/photos/mine', { token })).json<Json>()).rows as Json[]

describe('private photos', () => {
  it('are stored for their owner, who alone can read, list and delete them', async () => {
    const a = await signUp()
    const b = await signUp()
    const name = photo()
    const stored = await upload(a.token, privatePath(name), JPEG)
    expect(stored.status).toBe(200)
    expect(await stored.json()).toEqual({ name })
    const read = await request('GET', privatePath(name), { token: a.token })
    expect(read.status).toBe(200)
    expect(read.headers.get('content-type')).toBe('image/jpeg')
    expect(read.headers.get('cache-control')).toBe('private, no-store')
    expect(new Uint8Array(await read.arrayBuffer())).toEqual(JPEG)
    expect((await request('GET', privatePath(name), { token: b.token })).status).toBe(404)
    expect(await mine(a.token)).toEqual([{ bucket_id: PRIVATE_BUCKET, name }])
    expect(await mine(b.token)).toEqual([])
    expect((await request('DELETE', privatePath(name), { token: b.token })).status).toBe(204)
    expect(await env.GYM_PHOTOS_PRIVATE.head(name)).not.toBeNull()
    expect((await request('DELETE', privatePath(name), { token: a.token })).status).toBe(204)
    expect(await env.GYM_PHOTOS_PRIVATE.head(name)).toBeNull()
    expect(await rowsOf(name)).toBe(0)
    expect((await request('GET', privatePath(name), { token: a.token })).status).toBe(404)
    expect((await request('DELETE', privatePath(name), { token: a.token })).status).toBe(204)
  })
})

describe('an upload', () => {
  it('answers 409 for a name already uploaded, by the caller or by anyone', async () => {
    const a = await signUp()
    const b = await signUp()
    const name = photo()
    expect((await upload(a.token, privatePath(name), JPEG)).status).toBe(200)
    expect(await refusalOf(await upload(a.token, privatePath(name), JPEG), 409)).toEqual({
      code: 'duplicate', message: 'A photo with that name is already uploaded.',
    })
    expect((await refusalOf(await upload(b.token, privatePath(name), JPEG), 409)).code).toBe('duplicate')
  })

  it('refuses a bad name, a type or bytes that are not JPEG, and more than 1 MB', async () => {
    const { token } = await signUp()
    for (const name of [photo().toUpperCase(), 'photo.jpg', '..%2Fx.jpg', `${crypto.randomUUID()}.png`]) {
      expect(await refusalOf(await upload(token, privatePath(name), JPEG))).toEqual({
        code: 'photo_bad_name', message: 'A photo name is a lowercase UUID and .jpg.',
      })
    }
    expect((await refusalOf(await upload(token, privatePath(photo()), JPEG, 'image/svg+xml'))).code).toBe('photo_not_jpeg')
    expect((await refusalOf(await upload(token, privatePath(photo()), JPEG, 'application/octet-stream'))).code)
      .toBe('photo_not_jpeg')
    expect((await refusalOf(await upload(token, privatePath(photo()), new TextEncoder().encode('GIF89a')))).code)
      .toBe('photo_not_jpeg')
    expect((await refusalOf(await upload(token, privatePath(photo()), new Uint8Array(0)))).code).toBe('photo_not_jpeg')
    const atLimit = new Uint8Array(1_000_000)
    atLimit.set(JPEG)
    expect((await upload(token, privatePath(photo()), atLimit)).status).toBe(200)
    const over = new Uint8Array(1_000_001)
    over.set(JPEG)
    expect((await refusalOf(await upload(token, privatePath(photo()), over), 413)).code).toBe('too_large')
  })

  it("refuses a name a listing uses, the caller's or anyone's, after its object was deleted", async () => {
    const a = await signUp()
    const b = await signUp()
    const name = photo()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: a.userId, photo: name })
    for (const account of [a, b]) {
      expect(await refusalOf(await upload(account.token, sharedPath(name), JPEG))).toEqual({
        code: 'photo_name_in_use', message: 'A listing already uses that photo name.',
      })
    }
  })

  it('takes 60 a day across both buckets; the 61st is refused, a deletion frees a slot, older ones do not count',
    async () => {
      const a = await signUp()
      await photosToday(a.userId, 30, 'gym-photos')
      await photosToday(a.userId, 29, 'gym-photos-private')
      const sixtieth = photo()
      expect((await upload(a.token, privatePath(sixtieth), JPEG)).status).toBe(200)
      expect(await refusalOf(await upload(a.token, sharedPath(photo()), JPEG))).toEqual({
        code: 'photo_daily_limit', message: "You've uploaded a lot of photos today. Try again tomorrow.",
      })
      expect((await request('DELETE', privatePath(sixtieth), { token: a.token })).status).toBe(204)
      expect((await upload(a.token, sharedPath(photo()), JPEG)).status).toBe(200)
      expect((await refusalOf(await upload(a.token, sharedPath(photo()), JPEG))).code).toBe('photo_daily_limit')
      await agedRows('photo_objects', 'owner_id', a.userId)
      expect((await upload(a.token, sharedPath(photo()), JPEG)).status).toBe(200)
    })

  it('answers a retry of a finished upload with 409 even at the daily limit', async () => {
    const a = await signUp()
    await photosToday(a.userId, 59, 'gym-photos-private')
    const name = photo()
    expect((await upload(a.token, privatePath(name), JPEG)).status).toBe(200)
    expect((await refusalOf(await upload(a.token, privatePath(name), JPEG), 409)).code).toBe('duplicate')
  })

  it('finishes an upload whose object was never written when its owner sends it again, and nobody else', async () => {
    const a = await signUp()
    const b = await signUp()
    const name = await uploadedPhoto(a.userId, 'gym-photos-private', { stored: false })
    expect((await refusalOf(await upload(b.token, privatePath(name), JPEG), 409)).code).toBe('duplicate')
    expect(await env.GYM_PHOTOS_PRIVATE.head(name)).toBeNull()
    expect((await upload(a.token, privatePath(name), JPEG)).status).toBe(200)
    expect((await request('GET', privatePath(name), { token: a.token })).status).toBe(200)
    expect(await rowsOf(name)).toBe(1)
  })

  it('gives its row back when the object cannot be written', async () => {
    const { userId } = await signUp()
    const name = photo()
    const down = {
      put: async () => {
        throw new Error('R2 is down')
      },
      head: async () => null,
    } as unknown as R2Bucket
    await expect(uploadPhoto({ ...env, GYM_PHOTOS_PRIVATE: down }, userId, PRIVATE_BUCKET, name, 'image/jpeg', JPEG))
      .rejects.toThrow('R2 is down')
    expect(await rowsOf(name)).toBe(0)
  })

  it('refuses an owner whose account is gone', async () => {
    const attempt = uploadPhoto(env, crypto.randomUUID(), PRIVATE_BUCKET, photo(), 'image/jpeg', JPEG)
    await expect(attempt).rejects.toMatchObject({ code: 'photo_owner_missing' })
  })

  it('takes exactly 60 when 70 arrive together', async () => {
    const a = await signUp()
    const answers = await Promise.all(Array.from({ length: 70 }, () => upload(a.token, privatePath(photo()), JPEG)))
    expect(answers.filter((res) => res.status === 200)).toHaveLength(60)
    expect(answers.filter((res) => res.status === 422)).toHaveLength(10)
    expect(await mine(a.token)).toHaveLength(60)
  })
})

describe('shared photos', () => {
  it('are deleted by their owner, and by an admin only while a removed listing names them', async () => {
    const author = await signUp()
    const other = await signUp()
    const boss = await signUp()
    await makeAdmin(boss.userId)
    const name = photo()
    expect((await upload(author.token, sharedPath(name), JPEG)).status).toBe(200)
    const gym = await insertGym({ visibility: 'public', createdBy: author.userId })
    const listing = await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: author.userId, photo: name })
    for (const account of [other, boss]) {
      expect((await request('DELETE', sharedPath(name), { token: account.token })).status).toBe(204)
      expect(await env.GYM_PHOTOS.head(name)).not.toBeNull()
    }
    await setStatus('gym_equipment', listing, 'removed')
    expect((await request('DELETE', sharedPath(name), { token: boss.token })).status).toBe(204)
    expect(await env.GYM_PHOTOS.head(name)).toBeNull()
    expect(await rowsOf(name)).toBe(0)
    const own = await uploadedPhoto(author.userId, 'gym-photos')
    expect((await request('DELETE', sharedPath(own), { token: author.token })).status).toBe(204)
    expect(await env.GYM_PHOTOS.head(own)).toBeNull()
  })
})

describe('detaching photos', () => {
  it("clears the caller's own listing photos, private and shared, and moves them for sync", async () => {
    const a = await signUp()
    const b = await signUp()
    const item = await genericItem()
    const publicGym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const ownPrivate = await insertListing({
      gym: await insertGym({ visibility: 'private', owner: a.userId }), item, visibility: 'private', owner: a.userId,
      photo: photo(),
    })
    const ownPublic = await insertListing({ gym: publicGym, item, visibility: 'public', addedBy: a.userId, photo: photo() })
    const theirPublic = await insertListing({ gym: publicGym, item, visibility: 'public', addedBy: b.userId, photo: photo() })
    const theirPrivate = await insertListing({
      gym: await insertGym({ visibility: 'private', owner: b.userId }), item, visibility: 'private', owner: b.userId,
      photo: photo(),
    })
    expect((await request('POST', '/v1/photos/detach', { token: a.token })).status).toBe(204)
    const row = (id: string) => env.DB.prepare('SELECT photo_path, client_updated_at, updated_at FROM gym_equipment WHERE id = ?1')
      .bind(id).first<{ photo_path: string | null; client_updated_at: string; updated_at: string }>()
    for (const id of [ownPrivate, ownPublic]) {
      const after = (await row(id))!
      expect(after.photo_path).toBeNull()
      expect(after.client_updated_at > '2026-11-07T10:00:00.000000Z').toBe(true)
      expect(after.updated_at > '2026-11-07T10:00:00.000000Z').toBe(true)
    }
    for (const id of [theirPublic, theirPrivate]) expect((await row(id))!.photo_path).not.toBeNull()
    expect((await request('GET', `/v1/gyms/${publicGym}/listings`, { token: b.token })).status).toBe(200)
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/photos.test.ts`
Expected: FAIL. `../src/photos/store.ts` doesn't exist.

- [ ] **Step 3: Write `server/src/photos/store.ts`**

```ts
import type { Env } from '../env.ts'
import { Refusals } from '../gyms/refusals.ts'
import { ApiError } from '../http/errors.ts'
import { DomainLimits } from '../shared/domain-limits.ts'
import { DAY_AGO_SQL, laterStamp, NOW_SQL } from '../sync/time.ts'
import { bucketOf, type GymBucket, PHOTO_NAME, PRIVATE_BUCKET, SHARED_BUCKET } from './objects.ts'

// Gym photos (Storage with guard_gym_photo and the bucket policies, supabase/migrations/20261030000003_gym_photos_
// buckets.sql). R2 and D1 share no transaction, so:
// - an upload claims its photo_objects row first, in one conditional statement that holds every rule, then writes
//   the object; if the object can't be written, the row goes;
// - a delete removes the object first, then the row, so no object is ever left that nobody owns.
// A row whose object is missing (the Worker stopped in between) still counts and is still listed by /v1/photos/mine,
// so the app deletes it like any other; its owner uploading the same name finishes it.

/** The buckets' file_size_limit. */
export const MAX_PHOTO_BYTES = 1_000_000

const isJpeg = (bytes: Uint8Array) => bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff

/** What Storage and the trigger checked before anything was written: the name, the size, the type and the bytes. */
function checkUpload(name: string, contentType: string | undefined, bytes: Uint8Array): void {
  if (!PHOTO_NAME.test(name)) throw Refusals.photoBadName()
  if (bytes.byteLength > MAX_PHOTO_BYTES) throw new ApiError(413, 'too_large', 'A photo is at most 1 MB.')
  const type = (contentType ?? '').split(';')[0].trim().toLowerCase()
  if (type !== 'image/jpeg' || !isJpeg(bytes)) throw Refusals.photoNotJpeg()
}

/**
 * guard_gym_photo, as one statement: the owner's account exists, no listing uses the name (not even after its object
 * was deleted, so a removed listing's photo can't come back), and the owner uploaded fewer than 60 today in both
 * buckets. Deleting a photo frees a slot, as it did: only 60 stay stored per day, which is what the limit is for.
 */
const CLAIM = `INSERT INTO photo_objects (bucket, name, owner_id, created_at)
SELECT ?1, ?2, ?3, ${NOW_SQL}
WHERE EXISTS (SELECT 1 FROM "user" WHERE id = ?3)
  AND NOT EXISTS (SELECT 1 FROM gym_equipment WHERE photo_path = ?2)
  AND (SELECT count(*) FROM photo_objects WHERE owner_id = ?3
    AND created_at > ${DAY_AGO_SQL}) < ${DomainLimits.dailyPhotoUploads}
ON CONFLICT (bucket, name) DO NOTHING
RETURNING name`

const WHY_NOT = `SELECT (SELECT owner_id FROM photo_objects WHERE bucket = ?1 AND name = ?2) AS holder,
  EXISTS (SELECT 1 FROM "user" WHERE id = ?3) AS account,
  EXISTS (SELECT 1 FROM gym_equipment WHERE photo_path = ?2) AS in_use`

const putObject = (env: Env, bucket: GymBucket, name: string, bytes: Uint8Array) =>
  bucketOf(env, bucket).put(name, bytes, { httpMetadata: { contentType: 'image/jpeg' } })

export async function uploadPhoto(
  env: Env,
  me: string,
  bucket: GymBucket,
  name: string,
  contentType: string | undefined,
  bytes: Uint8Array,
): Promise<void> {
  checkUpload(name, contentType, bytes)
  const { results } = await env.DB.prepare(CLAIM).bind(bucket, name, me).all()
  if (results.length === 0) return finishOrRefuse(env, me, bucket, name, bytes)
  try {
    await putObject(env, bucket, name, bytes)
  } catch (error) {
    // The other half failed: give the row back, unless another upload of this name stored the object meanwhile.
    if ((await bucketOf(env, bucket).head(name)) === null) {
      await env.DB.prepare('DELETE FROM photo_objects WHERE bucket = ?1 AND name = ?2 AND owner_id = ?3')
        .bind(bucket, name, me).run()
    }
    throw error
  }
}

/**
 * The claim wrote nothing. A name already held answers 409, which the app takes as uploaded, unless it is the
 * caller's own unfinished upload: then this finishes it. Otherwise the refusal, in guard_gym_photo's order.
 */
async function finishOrRefuse(env: Env, me: string, bucket: GymBucket, name: string, bytes: Uint8Array) {
  const why = (await env.DB.prepare(WHY_NOT).bind(bucket, name, me)
    .first<{ holder: string | null; account: number; in_use: number }>())!
  if (why.holder !== null) {
    if (why.holder === me && (await bucketOf(env, bucket).head(name)) === null) {
      await putObject(env, bucket, name, bytes)
      return
    }
    throw Refusals.photoDuplicate()
  }
  if (why.account !== 1) throw Refusals.photoOwnerMissing()
  if (why.in_use === 1) throw Refusals.photoNameInUse()
  throw Refusals.photoDailyLimit()
}

/** An admin may delete a shared photo while a removed public listing names it (moderate_content handed it over). */
const ADMIN_MAY_DELETE = `SELECT 1 WHERE EXISTS (SELECT 1 FROM app_admins WHERE user_id = ?1)
  AND EXISTS (SELECT 1 FROM gym_equipment WHERE photo_path = ?2 AND visibility = 'public' AND status = 'removed')`

/** Deletes a photo the caller may delete; anything else is quietly left, as Storage's remove left what RLS hid. */
export async function deletePhoto(env: Env, me: string, bucket: GymBucket, name: string): Promise<void> {
  if (!PHOTO_NAME.test(name)) return
  const row = await env.DB.prepare('SELECT owner_id FROM photo_objects WHERE bucket = ?1 AND name = ?2')
    .bind(bucket, name).first<{ owner_id: string }>()
  if (row === null) return
  const allowed = row.owner_id === me ||
    (bucket === SHARED_BUCKET && (await env.DB.prepare(ADMIN_MAY_DELETE).bind(me, name).first()) !== null)
  if (!allowed) return
  await bucketOf(env, bucket).delete(name)
  await env.DB.prepare('DELETE FROM photo_objects WHERE bucket = ?1 AND name = ?2').bind(bucket, name).run()
}

/** A private photo of the caller's, or null: never anyone else's. */
export async function privatePhoto(env: Env, me: string, name: string): Promise<R2ObjectBody | null> {
  if (!PHOTO_NAME.test(name)) return null
  const owned = await env.DB.prepare('SELECT 1 FROM photo_objects WHERE bucket = ?1 AND name = ?2 AND owner_id = ?3')
    .bind(PRIVATE_BUCKET, name, me).first()
  return owned === null ? null : env.GYM_PHOTOS_PRIVATE.get(name)
}

/**
 * my_gym_photos: the caller's photos in both buckets, by owner and not by listing, so an upload that was never linked
 * is listed too. PostgREST capped it at 1,000 rows; the app lists again after each pass.
 */
export async function myPhotos(db: D1Database, me: string): Promise<{ bucket_id: string; name: string }[]> {
  const { results } = await db.prepare(
    'SELECT bucket AS bucket_id, name FROM photo_objects WHERE owner_id = ?1 ORDER BY bucket, name LIMIT 1000',
  ).bind(me).all<{ bucket_id: string; name: string }>()
  return results
}

/**
 * detach_my_gym_photos, for an account deletion that failed after the objects were removed: the caller's private
 * listings and the public ones they added lose the name, and their edit time moves so other phones take the change.
 */
export async function detachMyPhotos(db: D1Database, me: string): Promise<void> {
  await db.prepare(
    `UPDATE gym_equipment SET photo_path = NULL, client_updated_at = max(client_updated_at, ${NOW_SQL}),
       updated_at = ${laterStamp('gym_equipment.updated_at', NOW_SQL)}
     WHERE photo_path IS NOT NULL AND ((visibility = 'private' AND owner_id = ?1) OR (visibility = 'public' AND added_by = ?1))`,
  ).bind(me).run()
}
```

- [ ] **Step 4: Write `server/src/photos/routes.ts` and mount it**

```ts
import { type Context, Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { errorBody } from '../http/errors.ts'
import { type GymBucket, PRIVATE_BUCKET, SHARED_BUCKET } from './objects.ts'
import { deletePhoto, detachMyPhotos, myPhotos, privatePhoto, uploadPhoto } from './store.ts'

/** /v1/photos: the caller's gym photos (spec section 3, "Photos"). Shared photos are read at /photos/shared. */
export const photoRoutes = new Hono<AppEnv>()

const put = (bucket: GymBucket) => async (c: Context<AppEnv>) => {
  const name = c.req.param('name') ?? ''
  const bytes = new Uint8Array(await c.req.arrayBuffer())
  await uploadPhoto(c.env, c.var.userId, bucket, name, c.req.header('content-type'), bytes)
  return c.json({ name })
}

const remove = (bucket: GymBucket) => async (c: Context<AppEnv>) => {
  await deletePhoto(c.env, c.var.userId, bucket, c.req.param('name') ?? '')
  return c.body(null, 204)
}

photoRoutes.get('/mine', async (c) => c.json({ rows: await myPhotos(c.env.DB, c.var.userId) }))

photoRoutes.post('/detach', async (c) => {
  await detachMyPhotos(c.env.DB, c.var.userId)
  return c.body(null, 204)
})

/** The app keeps its URL cache off for these too (spec section 7). */
photoRoutes.get('/private/:name', async (c) => {
  const object = await privatePhoto(c.env, c.var.userId, c.req.param('name'))
  if (object === null) return c.json(errorBody('not_found', 'No such photo.'), 404)
  return new Response(object.body, {
    headers: { 'content-type': 'image/jpeg', 'cache-control': 'private, no-store', 'x-content-type-options': 'nosniff' },
  })
})

photoRoutes.put('/private/:name', put(PRIVATE_BUCKET))
photoRoutes.put('/shared/:name', put(SHARED_BUCKET))
photoRoutes.delete('/private/:name', remove(PRIVATE_BUCKET))
photoRoutes.delete('/shared/:name', remove(SHARED_BUCKET))
```

In `server/src/index.ts`, import it and mount it after the account routes:

```ts
import { photoRoutes } from './photos/routes.ts'
```

```ts
v1.route('/photos', photoRoutes)
```

The `/v1` body limit (1 MiB) stays as it is: it is above the photo limit, and the route answers `413 too_large`
past 1,000,000 bytes.

- [ ] **Step 5: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  22 passed (22)`, `Tests  266 passed (266)`.

- [ ] **Step 6: Commit**

```bash
git add server/src/photos server/src/index.ts server/test/helpers.ts server/test/gym-fixtures.ts \
  server/test/photos.test.ts
git commit -m "feat(server): gym photos in R2, owned in photo_objects"
```

- [ ] **Step 7: Review**

Ask **code-reviewer** for spec compliance (spec section 4 "Photos", decision 6). Then **security-reviewer**:
- a private photo is served only to its owner, with `private, no-store`;
- no name reaches R2 that isn't a lowercase UUID and `.jpg` (`%2F` is decoded before the check);
- an admin deletes only a removed listing's shared photo;
- no path leaves an object that nobody owns;
- 70 uploads at once give exactly 60.

---

### Task 9: Public photos, and exercise photos on the local Worker

`GET /photos/shared/:name` and `GET /photos/exercises/:name` (`manifest.json` included), with no session. Then
`scripts/upload-photos.mjs --target worker`, which fills the local `exercise-photos` bucket (decision 12).

**Files:**
- Create: `server/src/photos/public.ts`
- Modify: `server/src/index.ts`, `scripts/upload-photos.mjs`, `scripts/upload-photos.test.mjs`, `scripts/server-up.sh`,
  `docs/media/README.md`
- Test: `server/test/public-photos.test.ts`, `scripts/upload-photos.test.mjs`

- [ ] **Step 1: Write the failing tests**

`server/test/public-photos.test.ts` (from `exercise_photos_bucket.test.sql` and `gyms.test.sql` lines 151 and 332):

```ts
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import app from '../src/index.ts'
import { JPEG } from './gym-fixtures.ts'
import { ORIGIN } from './helpers.ts'

/** A request as a phone's image loader or the uploader makes it: no session. */
const fetchPublic = (path: string, init: RequestInit = {}) =>
  Promise.resolve(app.fetch(new Request(`${ORIGIN}${path}`, init), env))

describe('public photos', () => {
  it('serve a shared photo to anyone, with its ETag, and 304 while it is unchanged', async () => {
    const name = `${crypto.randomUUID()}.jpg`
    const stored = (await env.GYM_PHOTOS.put(name, JPEG))!
    const res = await fetchPublic(`/photos/shared/${name}`)
    expect(res.status).toBe(200)
    expect(Object.fromEntries(res.headers)).toMatchObject({
      'content-type': 'image/jpeg', 'cache-control': 'public, max-age=3600', etag: stored.httpEtag,
      'content-length': String(JPEG.length), 'x-content-type-options': 'nosniff',
    })
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(JPEG)
    const unchanged = await fetchPublic(`/photos/shared/${name}`, { headers: { 'if-none-match': stored.httpEtag } })
    expect(unchanged.status).toBe(304)
    expect(await unchanged.text()).toBe('')
    const head = await fetchPublic(`/photos/shared/${name}`, { method: 'HEAD' })
    expect(head.status).toBe(200)
    expect(head.headers.get('etag')).toBe(stored.httpEtag)
    expect(head.headers.get('content-length')).toBe(String(JPEG.length))
  })

  it('answer 404 for a missing photo, a name that could not be one, and a private photo', async () => {
    const privateName = `${crypto.randomUUID()}.jpg`
    await env.GYM_PHOTOS_PRIVATE.put(privateName, JPEG)
    const paths = [
      `/photos/shared/${privateName}`, `/photos/shared/${crypto.randomUUID()}.jpg`, '/photos/shared/..%2Fsecret.jpg',
      '/photos/shared/NOT-A-UUID.jpg', `/photos/private/${privateName}`,
    ]
    for (const path of paths) {
      const res = await fetchPublic(path)
      expect(res.status, path).toBe(404)
      expect(await res.json()).toMatchObject({ error: { code: 'not_found' } })
    }
  })

  it("serve GymRollins' own photos and the manifest, each with its cache time", async () => {
    const manifest = {
      version: 1, updatedAt: '2026-11-08T00:00:00.000Z', photos: { '0453': 1 }, rev: { '0453': 'ab12cd34ef56' }, kinds: {},
    }
    await env.EXERCISE_PHOTOS.put('own-0453-0.jpg', JPEG)
    await env.EXERCISE_PHOTOS.put('kind-leg-press.jpg', JPEG)
    await env.EXERCISE_PHOTOS.put('manifest.json', JSON.stringify(manifest))
    for (const name of ['own-0453-0.jpg', 'kind-leg-press.jpg']) {
      const res = await fetchPublic(`/photos/exercises/${name}?v=ab12cd34ef56`)
      expect(res.status).toBe(200)
      expect(res.headers.get('content-type')).toBe('image/jpeg')
      expect(res.headers.get('cache-control')).toBe('public, max-age=31536000')
    }
    const res = await fetchPublic('/photos/exercises/manifest.json')
    expect(res.headers.get('content-type')).toBe('application/json')
    expect(res.headers.get('cache-control')).toBe('public, max-age=60')
    expect(await res.json()).toEqual(manifest)
  })

  it('serve nothing else from the exercise bucket', async () => {
    await env.EXERCISE_PHOTOS.put('notes.txt', 'private notes')
    for (const name of ['notes.txt', 'own-abc-0.jpg', 'kind-Bad.jpg', '..%2Fmanifest.json']) {
      expect((await fetchPublic(`/photos/exercises/${name}`)).status, name).toBe(404)
    }
  })

  it('take no writes: gym photos go through /v1, exercise photos through the uploader', async () => {
    const writes: [string, string][] = [
      ['PUT', `/photos/shared/${crypto.randomUUID()}.jpg`], ['DELETE', '/photos/exercises/manifest.json'],
      ['POST', '/photos/exercises/own-1-0.jpg'],
    ]
    for (const [method, path] of writes) {
      const res = await fetchPublic(path, { method, body: method === 'DELETE' ? undefined : JPEG })
      expect(res.status, `${method} ${path}`).toBe(404)
    }
  })
})
```

In `scripts/upload-photos.test.mjs`, add `PATHS`, `runWrangler` and `workerClient` to the import from
`./upload-photos.mjs`, and add:

```js
/** The local Worker's public route over a map of objects, and a fake wrangler that writes into that map. */
function fakeWorker({ objects = {} } = {}) {
  const store = new Map(Object.entries(objects).map(([name, body]) => [name, Buffer.from(body)]))
  const runs = []
  const fetch = async (input, init = {}) => {
    const url = new URL(input)
    const prefix = '/photos/exercises/'
    const body = url.pathname.startsWith(prefix) ? store.get(decodeURIComponent(url.pathname.slice(prefix.length))) : null
    if (!body) return new Response('{"error":{"code":"not_found"}}', { status: 404 })
    const headers = { etag: `"${md5(body)}"`, 'content-length': String(body.length) }
    return new Response(init.method === 'HEAD' ? null : body, { status: 200, headers })
  }
  const run = async (args, input) => {
    runs.push(args)
    store.set(args[3].slice(`${BUCKET}/`.length), Buffer.from(input))
    return { status: 0, stderr: '' }
  }
  return { fetch, run, runs, store }
}

test('resolveTarget worker: the local Worker only, at WORKER_URL or 127.0.0.1:8787', () => {
  assert.equal(parseArgs(['--target', 'worker']).target, 'worker')
  assert.deepEqual(resolveTarget({ target: 'worker', env: {} }), { url: 'http://127.0.0.1:8787', worker: true })
  assert.deepEqual(resolveTarget({ target: 'worker', env: { WORKER_URL: 'http://localhost:9000/' } }),
    { url: 'http://localhost:9000', worker: true })
  assert.throws(() => resolveTarget({ target: 'worker', env: { WORKER_URL: 'https://gymrollins.example.workers.dev' } }),
    /not the local Worker/)
})

test('uploadPhotos --target worker: wrangler --local into server/.wrangler/state, then the manifest; again, a no-op',
  async () => {
    const dir = photoDir()
    const worker = fakeWorker()
    const { log } = quiet()
    const options = { url: 'http://127.0.0.1:8787', worker: true, dirs: [dir], fetch: worker.fetch, run: worker.run, log }
    const first = await uploadPhotos(options)
    assert.equal(first.uploaded, 3)
    assert.equal(first.manifest, 'uploaded')
    for (const args of worker.runs) {
      assert.ok(args.includes('--local'))
      assert.equal(args[args.indexOf('--persist-to') + 1], PATHS.workerState)
    }
    const last = worker.runs.at(-1)
    assert.equal(last[3], `${BUCKET}/manifest.json`)
    assert.equal(last[last.indexOf('--content-type') + 1], 'application/json')
    assert.deepEqual(JSON.parse(worker.store.get('manifest.json')).photos, { '0227': 1, '0453': 2 })
    const second = await uploadPhotos(options)
    assert.equal(second.uploaded, 0)
    assert.equal(second.skipped, 3)
    assert.equal(second.manifest, 'unchanged')
  })

test('runWrangler refuses to run wrangler without --local', async () => {
  await assert.rejects(runWrangler(['r2', 'object', 'put', `${BUCKET}/x.jpg`, '--pipe'], ''), /only with --local/)
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/public-photos.test.ts`
Expected: FAIL, with 404 for every photo.

Run: `node --test scripts/upload-photos.test.mjs`
Expected: FAIL. `runWrangler` and `workerClient` aren't exported.

- [ ] **Step 3: Write `server/src/photos/public.ts` and mount it**

```ts
import { type Context, Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { errorBody } from '../http/errors.ts'
import { PHOTO_NAME } from './objects.ts'

// Photos anyone can read, outside /v1 and its session (spec section 3): shared listing photos, and GymRollins' own
// exercise and kind photos with their manifest.json. Answers carry ETag and Cache-Control, and a matching
// If-None-Match gets 304, so phones and Cloudflare's edge keep copies. A removed listing's photo is served until
// moderation deletes it, as Supabase's public URLs served it. Nothing here writes: gym photos are uploaded through
// /v1/photos, and exercise photos by scripts/upload-photos.mjs.

/** The uploader's names: own-<exercise id>-<frame>.jpg and kind-<kind id>.jpg. */
const EXERCISE_PHOTO = /^(own-\d+-\d+|kind-[a-z0-9-]{1,40})\.jpg$/
const MANIFEST = 'manifest.json'

/** The app uploaded shared photos with an hour (FileOptions cacheControl "3600"); a deleted one leaves caches in it. */
const SHARED_CACHE = 'public, max-age=3600'
/** A regenerated exercise photo gets a new ?v=<rev> from the manifest, so an old URL can be kept for a year. */
const EXERCISE_CACHE = 'public, max-age=31536000'
/** The manifest says which ?v= is current; the uploader gave it a minute. */
const MANIFEST_CACHE = 'public, max-age=60'

const notFound = (c: Context<AppEnv>) => c.json(errorBody('not_found', 'No such photo.'), 404)

async function serve(c: Context<AppEnv>, bucket: R2Bucket, name: string, type: string, cacheControl: string) {
  const seen = c.req.header('if-none-match')
  const object = await bucket.get(name, seen ? { onlyIf: new Headers({ 'if-none-match': seen }) } : {})
  if (object === null) return notFound(c)
  const headers = new Headers({
    'content-type': type, 'cache-control': cacheControl, etag: object.httpEtag, 'x-content-type-options': 'nosniff',
  })
  if (!('body' in object)) return new Response(null, { status: 304, headers })
  headers.set('content-length', String(object.size))
  return new Response(object.body, { headers })
}

/** /photos. Hono answers HEAD from these GET routes, without the body. */
export const publicPhotoRoutes = new Hono<AppEnv>()

publicPhotoRoutes.get('/shared/:name', (c) => {
  const name = c.req.param('name')
  return PHOTO_NAME.test(name) ? serve(c, c.env.GYM_PHOTOS, name, 'image/jpeg', SHARED_CACHE) : notFound(c)
})

publicPhotoRoutes.get('/exercises/:name', (c) => {
  const name = c.req.param('name')
  if (name === MANIFEST) return serve(c, c.env.EXERCISE_PHOTOS, name, 'application/json', MANIFEST_CACHE)
  return EXERCISE_PHOTO.test(name) ? serve(c, c.env.EXERCISE_PHOTOS, name, 'image/jpeg', EXERCISE_CACHE) : notFound(c)
})
```

In `server/src/index.ts`, import it and mount it after `app.route('/v1', v1)`:

```ts
import { publicPhotoRoutes } from './photos/public.ts'
```

```ts
app.route('/photos', publicPhotoRoutes)
```

- [ ] **Step 4: Add the local Worker to `scripts/upload-photos.mjs`**

1. In the header comment, after the `--target remote` lines, add:

```js
//   --target worker:          the local Worker (scripts/server-up.sh) at WORKER_URL or http://127.0.0.1:8787. Writes go
//                             through `wrangler r2 object put --local` into server/.wrangler/state, the folder
//                             `wrangler dev` reads; reads go through the Worker's /photos/exercises route. Loopback only.
```

2. Change the `node:fs` import line's neighbours to add:

```js
import { spawn } from 'node:child_process'
```

3. Add to `PATHS`:

```js
  /** The local Worker's project and state folder (wrangler dev's default, named in scripts/server-up.sh). */
  serverDir: resolve(ROOT, 'server'),
  workerState: resolve(ROOT, 'server/.wrangler/state'),
```

and below `PATHS`:

```js
const DEFAULT_WORKER_URL = 'http://127.0.0.1:8787'
```

4. In `parseArgs`, replace the target check with:

```js
      if (!['local', 'remote', 'worker'].includes(args.target)) {
        throw new Error(`--target must be local, remote or worker, got "${args.target}"`)
      }
```

5. At the top of `resolveTarget`'s body, add:

```js
  if (target === 'worker') {
    const url = trimSlash(env.WORKER_URL?.trim() || DEFAULT_WORKER_URL)
    if (!isLocalUrl(url)) throw new Error(`WORKER_URL (${url}) is not the local Worker; remote buckets come with the deploy`)
    return { url, worker: true }
  }
```

6. Add after `storageClient`:

```js
/**
 * The local Worker. Writes go through `wrangler r2 object put --local` into server/.wrangler/state, which a running
 * `wrangler dev` sees at once; reads go through the Worker's public route, whose ETag is the object's MD5. Only the
 * local photos' names are looked up: nothing else writes this local bucket.
 */
export function workerClient({ url, fetch, run = runWrangler }) {
  const publicURL = name => `${url}/photos/exercises/${encodeURIComponent(name)}`

  async function list(local = []) {
    const objects = new Map()
    for (const { name } of local) {
      const response = await fetch(publicURL(name), { method: 'HEAD' })
      if (response.status === 404) continue
      if (!response.ok) throw new Error(`Reading ${name} from the local Worker failed: HTTP ${response.status}`)
      objects.set(name, {
        size: Number(response.headers.get('content-length')),
        etag: String(response.headers.get('etag') ?? '').replaceAll('"', ''),
      })
    }
    return objects
  }

  async function upload(name, body, contentType, cacheControl) {
    const args = ['r2', 'object', 'put', `${BUCKET}/${name}`, '--local', '--persist-to', PATHS.workerState, '--pipe',
      '--content-type', contentType, '--cache-control', cacheControl]
    const { status, stderr } = await run(args, body)
    if (status !== 0) throw new Error(`wrangler exited with ${status}: ${String(stderr).trim().split('\n').pop()}`)
  }

  async function storedJSON(name) {
    const response = await fetch(publicURL(name), { headers: { 'cache-control': 'no-cache' } })
    if (!response.ok) return null
    try { return await response.json() } catch { return null }
  }

  return { list, upload, storedJSON }
}

/** `npx wrangler <args>` in server/, with `input` on stdin. Never without --local: no Cloudflare account is used. */
export function runWrangler(args, input) {
  if (!args.includes('--local')) return Promise.reject(new Error('wrangler runs only with --local here'))
  return new Promise((done, fail) => {
    const child = spawn('npx', ['wrangler', ...args], { cwd: PATHS.serverDir, stdio: ['pipe', 'ignore', 'pipe'] })
    let stderr = ''
    child.stderr.on('data', chunk => { stderr += chunk })
    child.on('error', fail)
    child.on('close', status => done({ status, stderr }))
    child.stdin.end(input)
  })
}
```

7. In `uploadPhotos`:
   - add `worker = false, run = runWrangler` to its parameters;
   - replace `const client = storageClient({ url, key, fetch })` with
     `const client = worker ? workerClient({ url, fetch, run }) : storageClient({ url, key, fetch })`;
   - change both `await client.list()` calls to `await client.list(local)`; the Storage client ignores the argument;
   - change `forEachLimited(upload, CONCURRENCY, …)` to `forEachLimited(upload, worker ? 1 : CONCURRENCY, …)`. Each
     `wrangler` run starts its own local R2, so they go one at a time (about a second each).

8. In `main`, pass the target through:

```js
  const { url, key, worker } = resolveTarget({ target: args.target })
  const dirs = args.dirs.length > 0 ? args.dirs.map(d => resolve(d)) : PATHS.photoDirs
  const summary = await uploadPhotos({ url, key, worker, dirs, dryRun: args.dryRun })
```

- [ ] **Step 5: Name the state folder in `scripts/server-up.sh`, and document the Worker target**

In `scripts/server-up.sh`, make the shared folder explicit on both commands:

```bash
npx wrangler d1 migrations apply gymrollins --local --persist-to .wrangler/state < /dev/null
exec npx wrangler dev --local --persist-to .wrangler/state
```

In `docs/media/README.md`, add at the end of section 4 ("Hosting"):

```markdown
### The local Worker (plan 28)

The Cloudflare Worker serves the same bucket at `<API_URL>/photos/exercises/<name>` (`manifest.json` included), from
R2. Locally, with `scripts/server-up.sh` running:

    node scripts/upload-photos.mjs --target worker --dry-run
    node scripts/upload-photos.mjs --target worker

It writes with `wrangler r2 object put --local` into `server/.wrangler/state` (no Cloudflare account) and reads back
through the Worker, so a second run uploads nothing. `WORKER_URL` overrides `http://127.0.0.1:8787` (loopback only).
The app switches `PHOTO_HOSTING = storage` to the Worker in the iOS part of plan 28; the deployed bucket is filled
after the deploy (plan 30's checklist).
```

- [ ] **Step 6: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  23 passed (23)`, `Tests  271 passed (271)`.

Run: `node --test scripts/upload-photos.test.mjs`
Expected: `# pass 24`, `# fail 0` (21 before this task).

- [ ] **Step 7: Check it by hand against the local Worker**

```bash
scripts/server-up.sh                                   # one terminal
node scripts/upload-photos.mjs --target worker         # another: uploads the bundled photos, then the manifest
curl -sI http://127.0.0.1:8787/photos/exercises/manifest.json | grep -iE '^(HTTP|etag|cache-control)'
node scripts/upload-photos.mjs --target worker         # the second run
```

Expected: `HTTP/1.1 200 OK`, an `ETag`, and `Cache-Control: public, max-age=60`. The second run ends
`done: 0 uploaded, N skipped, 0 failed; manifest unchanged (M exercises)`. (Checked while writing this plan, against
`wrangler dev --local` on a scratch copy with two test photos.)

- [ ] **Step 8: Commit**

```bash
git add server/src/photos/public.ts server/src/index.ts server/test/public-photos.test.ts scripts/upload-photos.mjs \
  scripts/upload-photos.test.mjs scripts/server-up.sh docs/media/README.md
git commit -m "feat(server): public photo routes, and exercise photos on the local Worker"
```

- [ ] **Step 9: Review**

Ask **code-reviewer** to check the routes against spec section 3 ("Public … cached") and section 7 ("Public photos
carry no user ids in their names"). Then **security-reviewer**:
- the public routes read only the two public buckets;
- names are checked after decoding;
- `runWrangler` can't run without `--local`, and the Worker target accepts loopback only.

---

### Task 10: Account deletion with photos, isolation, limits together, and finish

The end-to-end checks the spec asks for (section 8): account deletion with photos uploaded through the routes, one
isolation test per gym table, and every daily limit and cap under requests that arrive together.

**Files:**
- Modify: `server/test/account.test.ts`, `server/README.md`
- Test: `server/test/gym-isolation.test.ts`, `server/test/limits.test.ts`

- [ ] **Step 1: Write the tests**

In `server/test/account.test.ts`, add `JPEG` to the import from `./gym-fixtures.ts` and `upload` to the import from
`./helpers.ts`, and add inside `describe('deleting an account', …)`:

```ts
  it('refuses while photos uploaded through the routes are left, then goes once they are deleted', async () => {
    const { token, userId } = await signUp()
    const names = [`${crypto.randomUUID()}.jpg`, `${crypto.randomUUID()}.jpg`]
    expect((await upload(token, `/v1/photos/private/${names[0]}`, JPEG)).status).toBe(200)
    expect((await upload(token, `/v1/photos/shared/${names[1]}`, JPEG)).status).toBe(200)
    const refused = await request('DELETE', '/v1/account', { token })
    expect(refused.status).toBe(422)
    expect(await refused.json()).toMatchObject({ error: { code: 'photos_remain' } })
    const listed = await request('GET', '/v1/photos/mine', { token })
    const { rows } = await listed.json<{ rows: { bucket_id: string; name: string }[] }>()
    expect(rows).toHaveLength(2)
    for (const { bucket_id, name } of rows) {
      const bucket = bucket_id === 'gym-photos' ? 'shared' : 'private'
      expect((await request('DELETE', `/v1/photos/${bucket}/${name}`, { token })).status).toBe(204)
    }
    expect((await request('DELETE', '/v1/account', { token })).status).toBe(204)
    expect(await env.GYM_PHOTOS_PRIVATE.head(names[0])).toBeNull()
    expect(await env.GYM_PHOTOS.head(names[1])).toBeNull()
    for (const [table, column] of OWNED) expect(await rowsNaming(table, column, userId), `${table}.${column}`).toBe(0)
  })
```

`server/test/gym-isolation.test.ts`:

```ts
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { blocksToday, genericItem, insertGym, insertListing, JPEG, makeAdmin, unblocksToday } from './gym-fixtures.ts'
import { request, signUp, upload } from './helpers.ts'
import { appUUID, T1, T2 } from './samples.ts'

// Spec section 8: for every table, account B can't read, change or delete account A's rows. Plan 26 covered its
// tables; sync-gyms.test.ts and sync-rows.test.ts cover pulls and pushes of private gyms and listings. This covers
// the rest of the gym tables.

type Json = Record<string, any>
const json = async (res: Response) => res.json<Json>()
const privateGym = () => ({
  id: appUUID(), visibility: 'private', name: 'Home', address: null, latitude: null, longitude: null,
  client_updated_at: T1, deleted_at: null,
})

describe("one account's gym data, as another account meets it", () => {
  it("private gyms: another account can't tombstone or pull them", async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = privateGym()
    expect((await request('POST', '/v1/sync/gyms', { token: a.token, body: { rows: [gym] } })).status).toBe(200)
    const tombstone = { ...gym, deleted_at: T2, client_updated_at: T2 }
    expect((await request('POST', '/v1/sync/gyms', { token: b.token, body: { rows: [tombstone] } })).status).toBe(403)
    expect((await json(await request('GET', '/v1/sync/gyms', { token: b.token }))).rows).toEqual([])
    expect((await json(await request('GET', '/v1/sync/gyms', { token: a.token }))).rows[0]).toMatchObject({ deleted_at: null })
  })

  it("photos: another account can't read, list, replace or delete them", async () => {
    const a = await signUp()
    const b = await signUp()
    const privateName = `${crypto.randomUUID()}.jpg`
    const sharedName = `${crypto.randomUUID()}.jpg`
    expect((await upload(a.token, `/v1/photos/private/${privateName}`, JPEG)).status).toBe(200)
    expect((await upload(a.token, `/v1/photos/shared/${sharedName}`, JPEG)).status).toBe(200)
    expect((await request('GET', `/v1/photos/private/${privateName}`, { token: b.token })).status).toBe(404)
    expect((await json(await request('GET', '/v1/photos/mine', { token: b.token }))).rows).toEqual([])
    const other = new Uint8Array([0xff, 0xd8, 0xff, 0x01])
    expect((await upload(b.token, `/v1/photos/private/${privateName}`, other)).status).toBe(409)
    expect((await upload(b.token, `/v1/photos/shared/${sharedName}`, other)).status).toBe(409)
    for (const path of [`/v1/photos/private/${privateName}`, `/v1/photos/shared/${sharedName}`]) {
      expect((await request('DELETE', path, { token: b.token })).status).toBe(204)
    }
    const kept = await env.GYM_PHOTOS_PRIVATE.get(privateName)
    expect(new Uint8Array(await kept!.arrayBuffer())).toEqual(JPEG)
    expect(await env.GYM_PHOTOS.head(sharedName)).not.toBeNull()
  })

  it("confirmations: one account's don't count as another's", async () => {
    const author = await signUp()
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: author.userId })
    const listing = await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: author.userId })
    expect(await json(await request('POST', `/v1/listings/${listing}/confirm`, { token: a.token }))).toEqual({ confirm_count: 1 })
    const seen = (await json(await request('GET', `/v1/gyms/${gym}/listings`, { token: b.token }))).rows[0]
    expect(seen).toMatchObject({ confirm_count: 1, confirmed_by_me: false })
  })

  it("blocks and unblocks: one account's change only what it sees and what it may still do", async () => {
    const author = await signUp()
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: author.userId })
    const listing = await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: author.userId })
    const blocked = await request('POST', '/v1/blocks', { token: a.token, body: { target_type: 'listing', target_id: listing } })
    expect(blocked.status).toBe(204)
    expect((await json(await request('GET', `/v1/gyms/${gym}/listings`, { token: b.token }))).rows).toHaveLength(1)
    expect(await json(await request('DELETE', '/v1/blocks', { token: b.token }))).toEqual({ cleared: 0 })
    expect((await json(await request('GET', `/v1/gyms/${gym}/listings`, { token: a.token }))).rows).toEqual([])
    await unblocksToday(a.userId, 3)
    await blocksToday(b.userId, 1)
    expect(await json(await request('DELETE', '/v1/blocks', { token: b.token }))).toEqual({ cleared: 1 })
  })

  it('reports: nobody reads them back, and the queue never names a reporter', async () => {
    const author = await signUp()
    const a = await signUp()
    const boss = await signUp()
    await makeAdmin(boss.userId)
    const gym = await insertGym({ visibility: 'public', createdBy: author.userId })
    const body = { target_type: 'gym', target_id: gym, reason: 'spam', note: null }
    expect((await request('POST', '/v1/reports', { token: a.token, body })).status).toBe(200)
    expect((await request('GET', '/v1/reports', { token: a.token })).status).toBe(404)
    const row = (await json(await request('GET', '/v1/admin/queue', { token: boss.token }))).rows
      .find((r: Json) => r.target_id === gym)
    expect(row).toBeDefined()
    expect(JSON.stringify(row)).not.toContain(a.userId)
  })

  it('the catalogue: written only by sharing, never by a push of public rows', async () => {
    const a = await signUp()
    const gym = privateGym()
    expect((await request('POST', '/v1/sync/gyms', { token: a.token, body: { rows: [gym] } })).status).toBe(200)
    const listing = {
      id: appUUID(), gym_id: gym.id, item_id: await genericItem(), visibility: 'public', photo_path: null,
      loads: { type: 'none' }, quantity: 1, notes: null, private_brand: null, private_model: null, client_updated_at: T1,
      deleted_at: null,
    }
    const res = await request('POST', '/v1/sync/gym-listings', { token: a.token, body: { rows: [listing] } })
    expect(res.status).toBe(422)
    expect((await json(res)).error.code).toBe('row_rejected')
    const writes: [string, string][] = [['POST', '/v1/items'], ['POST', '/v1/gyms/public'], ['PUT', `/v1/gyms/${gym.id}/listings`]]
    for (const [method, path] of writes) {
      expect((await request(method, path, { token: a.token, body: {} })).status, `${method} ${path}`).toBe(404)
    }
  })

  it("admins: one account's role gives another nothing", async () => {
    const boss = await signUp()
    const b = await signUp()
    await makeAdmin(boss.userId)
    expect(await json(await request('GET', '/v1/admin/me', { token: b.token }))).toEqual({ admin: false })
    expect((await request('GET', '/v1/admin/queue', { token: b.token })).status).toBe(403)
  })
})
```

`server/test/limits.test.ts`:

```ts
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { genericItem, insertGym, insertListing, insertUser, listingsSharedToday } from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'
import { appUUID, T1 } from './samples.ts'

// Requests that arrive together: each limit holds at its exact number, because every count sits in the statement that
// writes and D1 runs writes one at a time (spec section 2, "Locks and limits"). share.test.ts and photos.test.ts do
// the same for shares (35 → 30) and photo uploads (70 → 60).

const together = (count: number, call: (i: number) => Promise<Response>) =>
  Promise.all(Array.from({ length: count }, (_, i) => call(i)))
const tally = (answers: Response[]) =>
  answers.reduce<Record<number, number>>((counts, res) => ({ ...counts, [res.status]: (counts[res.status] ?? 0) + 1 }), {})

describe('limits, with requests that arrive together', () => {
  it('create exactly 10 new gyms out of 15', async () => {
    const { token } = await signUp()
    const answers = await together(15, () => request('POST', '/v1/gyms/find-or-create', {
      token, body: { maps_place_id: `place-${crypto.randomUUID()}`, name: 'Gym' },
    }))
    expect(tally(answers)).toEqual({ 200: 10, 422: 5 })
  })

  it('file exactly 20 reports out of 25', async () => {
    const { token } = await signUp()
    const author = await insertUser()
    const listings = await listingsSharedToday(await insertGym({ visibility: 'public', createdBy: author }), author, 25)
    const answers = await together(25, (i) => request('POST', '/v1/reports', {
      token, body: { target_type: 'listing', target_id: listings[i], reason: 'spam', note: null },
    }))
    expect(tally(answers)).toEqual({ 200: 20, 422: 5 })
  })

  it('make exactly 20 new blocks out of 25', async () => {
    const { token } = await signUp()
    const authors = await Promise.all(Array.from({ length: 25 }, () => insertUser()))
    const gym = await insertGym({ visibility: 'public', createdBy: authors[0] })
    const item = await genericItem()
    const listings = await Promise.all(authors.map((author) => insertListing({ gym, item, visibility: 'public', addedBy: author })))
    const answers = await together(25, (i) => request('POST', '/v1/blocks', {
      token, body: { target_type: 'listing', target_id: listings[i] },
    }))
    expect(tally(answers)).toEqual({ 204: 20, 422: 5 })
  })

  it('confirm exactly 100 listings out of 105', async () => {
    const { token } = await signUp()
    const author = await insertUser()
    const listings = await listingsSharedToday(await insertGym({ visibility: 'public', createdBy: author }), author, 105)
    const answers = await together(105, (i) => request('POST', `/v1/listings/${listings[i]}/confirm`, { token }))
    expect(tally(answers)).toEqual({ 200: 100, 422: 5 })
  })

  it('keep 100 live private gyms', async () => {
    const { token, userId } = await signUp()
    const gym = () => ({
      id: appUUID(), visibility: 'private', name: 'Home', address: null, latitude: null, longitude: null,
      client_updated_at: T1, deleted_at: null,
    })
    expect((await request('POST', '/v1/sync/gyms', { token, body: { rows: Array.from({ length: 96 }, gym) } })).status)
      .toBe(200)
    const answers = await together(6, () => request('POST', '/v1/sync/gyms', { token, body: { rows: [gym()] } }))
    expect(tally(answers)).toEqual({ 200: 4, 422: 2 })
    const live = await env.DB.prepare('SELECT count(*) AS n FROM gyms WHERE owner_id = ?1 AND deleted_at IS NULL')
      .bind(userId).first<{ n: number }>()
    expect(live!.n).toBe(100)
  })
})
```

- [ ] **Step 2: Run them**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  25 passed (25)`, `Tests  284 passed (284)`. These tests check what Tasks 4–9 built, so they pass at
once. If one fails, fix the code it names, not the test.

- [ ] **Step 3: Update `server/README.md`**

Replace the `/v1` bullet list and the D1 line with:

```markdown
- **The app's routes** at `/v1`, all behind the session:
  - `/v1/sync/*` (profile, plan, body weight, workouts, private gyms and listings),
  - the shared gym catalogue: `/v1/gyms`, `/v1/items`, `/v1/listings`,
  - moderation: `/v1/reports`, `/v1/blocks`, `/v1/admin`,
  - gym photos: `/v1/photos`,
  - `DELETE /v1/account`.
- **Public photos** at `/photos/shared/*` and `/photos/exercises/*`, with no session.
- **D1** holds the data (`migrations/`), and **R2** the photos: `gym-photos`, `gym-photos-private` and
  `exercise-photos`. Plan 29 adds the MCP server.
```

and add after the schema list:

```markdown
- `0005_gyms_photos.sql` adds the catalogue's fold keys and the private caps (triggers).

Exercise photos for the local Worker: `node ../scripts/upload-photos.mjs --target worker` while the server runs.
```

- [ ] **Step 4: Run everything this plan touched**

```bash
cd server && npx vitest run && npx tsc --noEmit && cd ..
node --test scripts/upload-photos.test.mjs
node scripts/gen-equipment-seed.mjs --check && node scripts/gen-exercise-seed.mjs --check
```

Expected: `Tests  284 passed (284)`, `# pass 24` and `# fail 0`, and both seed checks match. The seeds are untouched: 0005 alters the
table after them.

- [ ] **Step 5: Commit**

```bash
git add server/test/account.test.ts server/test/gym-isolation.test.ts server/test/limits.test.ts server/README.md
git commit -m "test(server): gym isolation, limits under load, and account deletion with photos"
```

- [ ] **Step 6: Review and outcome**

Ask **code-reviewer** and **security-reviewer** for the whole plan's diff (`git diff <plan-28 base>..HEAD -- server
scripts`). Then add `## Outcome` to this plan, as plan 26 did: commits per task, final counts, how the build differs
from the plan as written, what passes to the iOS part and to plans 29 and 30.

---

## Self-review against the spec

**Coverage**

| Spec | Where |
|---|---|
| §3 three R2 buckets and their roles | Task 1 (bindings), Task 8 (`/v1/photos`), Task 9 (public routes) |
| §3 `photo_objects` in place of `storage.objects` | Tasks 4, 8 (owner, bucket, name, created_at) |
| §3 the Gyms, Moderation and Photos routes | Tasks 5, 6 (gyms, items, listings), 7 (reports, blocks, admin), 8–9 (photos) |
| §3 type mapping (lowercase uuids, one timestamp form, JSON as text) | Task 4 (entity columns), `uuidOf`, `NOW_SQL`, compact loads |
| §4 every limit at its number and code | Task 4 (100 gyms, 1,000 listings), Task 6 (10 gyms, 30 shares, 100 confirmations, 300 a gym), Task 7 (20 reports, 20 blocks, 3 unblock-alls), Task 8 (60 photos); together in Tasks 6, 8, 10 |
| §4 moderation rules (3 reports, `own`, `already`, `duplicates`) | Tasks 6 and 7 |
| §4 photo checks (name, JPEG, 1 MB, owner, name unused, 60 a day), 409 | Task 8 |
| §4 account deletion with `photos_remain` | plan 26's `deleteAccount`; Task 10 through the routes |
| §6 error codes keep their strings | `src/gyms/refusals.ts`; every code has a test (Tasks 4–9) |
| §7 user id only from the session; admin needs `app_admins` and a session | every route reads `c.var.userId`; Task 7 |
| §7 `clean_text` on names, addresses, notes and report notes; the loads shape | Tasks 3, 4, 6, 7 |
| §7 private photos `private, no-store`; public names carry no user id | Tasks 8, 9 (`PHOTO_NAME`) |
| §8 isolation for every table | Task 4 (gyms, listings), Task 10 (photos, confirmations, blocks, unblocks, reports, admins, the catalogue) |
| §8 every photo refusal; deletion leaves zero rows | Tasks 8, 10 |
| §8 the drift test (Swift, TypeScript and SQL) | Tasks 1 and 4 |
| the pgTAP files this plan replaces | each test file names the pgTAP lines it covers |

**Where the spec is followed differently, and why** (each is also a decision above)
1. **Photos and their rows.** §4 says the object and its row "are written together; if the row fails, the object is
   deleted". This plan claims the row first, then writes the object, and gives the row back if the object fails
   (decision 6, as plan 26's outcome asked).
   - The claim is the one statement that holds the rules, so 70 uploads at once can't all write objects first.
   - A failed compensation leaves a row the app can see and delete, never an object nobody owns.
2. **Statuses.** §6 lists 401, 403, 404, 409, 422, 429 and 5xx. Plan 26 already answers 400 (bad input) and 413 (body
   too large). This plan uses 400 for what Postgres raised as 22023 or 22P02, and 413 for a photo over 1 MB.
3. **The drift test** "moves" in §8, but the Supabase functions still run until plan 30. So the Deno test stays for the
   Supabase copy, and the server gets its own Vitest test against the same Swift file.
4. **Anonymous catalogue reads.** §3 puts every `/v1` route behind the session, which drops the anon reads Supabase
   allowed (decision 7). Decided so: see "Questions the owner's side decided".

**Placeholders:** none. Every step has its code, command and expected output. The test counts were checked while
writing: Tasks 1–10 were applied to a scratch copy of `server/` (never committed), giving `Test Files  25 passed
(25)`, `Tests  284 passed (284)`, a clean `tsc`, and `# pass 24` for the uploader.

**Names used across tasks:**
- `Refusals.*`, `PHOTO_NAME`, `SHARED_BUCKET` / `PRIVATE_BUCKET`, `ownedStoredPhotos`, `DAY_AGO_SQL`, `PushContext`,
  `ownerOf`.
- The fixtures: `uploadedPhoto`, `photosToday`, `gymsCreatedToday`, `listingsSharedToday`, `reportsToday`,
  `blocksToday`, `unblocksToday`, `insertUser`, `agedRows`, `DAYS_AGO`, `JPEG`.
- The helper `upload`.

Each is defined once, in the task that first needs it.

## Questions the owner's side decided

Both were decided on 2026-11-08 by the controller, following the approved spec (iOS decisions 16 and 17):
1. **A signed-out phone doesn't read the shared catalogue.** Supabase let it, with the anon key. Now every `/v1`
   route answers 401 without the session, and the app shows its signed-out state.
2. **An admin deletes a shared photo only while a removed listing names it.** The Postgres policy let an admin delete
   any shared photo; the app never did more than this.

### Added after review (plan 28 server)

First batch (`7e85e06`):
- **Cap triggers count live rows only.** `0005_gyms_photos.sql` adds `gyms_owner_live` and `gym_equipment_owner_live`
  (`WHERE deleted_at IS NULL`), so the private-cap triggers never read tombstones. `schema.test.ts` checks each
  trigger's query plan.
- **Strings inside JSON columns.** `isStorableJson` (`sync/columns.ts`) checks every string and key in a `json` value.
  U+0000 or half a UTF-16 pair answers `row_rejected`.
- **Greek final sigma.** `foldKey` maps `ς` to `σ`, so `ΟΔΟΣ` and `οδοσ` are one item.
- **Bearer-only sessions.** `requireUser` gives Better Auth only the `authorization` header, so a bearer that fails its
  signature can't fall back to a session cookie.
- **Check-then-write races.** The confirm insert repeats `CONFIRMABLE_WHERE`, and the report insert needs a live public
  target. A race answers `unknown_listing` / `unknown_target` and stores nothing (`changedBeforeBatch` in the tests).
- **Password sign-in on this machine only.** `passwordAuthAllowed` also needs a `PUBLIC_BASE_URL` host of `127.0.0.1`
  or `localhost`.
- **Tests that needed no code change:** reviving tombstones past the cap, an item leaving `/v1/items` with its only gym,
  two listings naming one photo, restoring an active target resolving its reports, and `gym-listings` in the shared
  sync samples.

Second batch:
- **An upload racing a delete.** After the put, the upload reads its `(bucket, name, owner)` row again. If a delete
  took it meanwhile, the object goes too and the answer is `422 photo_missing`, never 409 (which the app takes as
  uploaded). The same holds when finishing an unfinished upload.
- **Shared photos are served only while a listing uses them.** `GET /photos/shared/:name` answers 404 unless a public
  listing that isn't removed (active or flagged) names it. Items take their photo from such a listing, so every photo
  the app shows is still served. An unused upload isn't served (no free file hosting), and a removed listing's photo
  stops at once. This replaces the last bullet of decision 11.
- **Detach skips removed listings**, so an admin can still delete their photos. Deleting a photo someone else owns,
  outside the admin rule, answers `403 not_allowed`. A name with nothing there still answers 204.
- **Finishing an unfinished upload** is refused with `422 photo_name_in_use` while a listing names it.
- **The public routes' input.** An `If-None-Match` that isn't `*` or a list of strong or weak quoted ETags gets a plain
  read; R2 threw "Invalid ETag" for it, a 500. Exercise names are `own-\d{1,6}-\d{1,6}`.
- **CSP.** Every photo answer, private and public, carries `content-security-policy: default-src 'none'; sandbox` next
  to `nosniff` (`PHOTO_HEADERS`).
- **Strict Apple nonce.** `authHandler` decodes the id token's payload (unverified; Better Auth verifies it next). It
  answers `400 bad_request` unless the `nonce` claim is the SHA-256 hex of the raw nonce sent. Better Auth alone also
  took the claim itself sent back, so anyone holding a token could replay it for its hour. A wrong nonce is now 400,
  not 401.
- **No stored provider tokens.** `databaseHooks.account` (`create` and `update`, `before`) sets `idToken`,
  `accessToken` and `refreshToken` to null. `encryptOAuthTokens` doesn't cover id tokens.
- **For the iOS tasks.**
  - In Task 16, `onlyTheOwnerCanDeleteAnUploadedPhoto` must expect an unlinked upload not to be served, and another
    user's delete to throw `.notAllowed`.
  - In the moderation queue, a removed listing whose photo still has to be deleted shows the placeholder thumbnail.

## iOS tasks

Built on plan 27 as committed (`f3395a2` and the code after it): `ApiError`, `ApiClient`, `ApiConfig`,
`ApiSyncTransport`, `servesGyms`, the server move, `AuthService(api:)`, the integration support and
`scripts/test-server.sh`.

**What the iOS part delivers:**
- `ApiGymCatalogTransport` behind `GymCatalogTransport`, in place of `UnavailableGymCatalogTransport`;
- gyms, listings and private photos in `ApiSyncTransport` (`servesGyms` becomes true);
- `GymCatalogErrors.map` reading `ApiError`;
- the server move forgetting the old catalogue;
- `PHOTO_HOSTING = storage` reading the Worker;
- the five parked gym suites back, on the Worker;
- the server-move check with gym links.

### Decisions for the iOS part

16. **Catalogue reads need a session**, decided by the controller on 2026-11-08, following the approved spec (open
    question 1). A signed-out phone hears `.signedOut` for every catalogue call, reads included, and the app shows its
    signed-out state. Supabase let the anon key read; the ported suites check the new answer instead.
17. **An admin deletes a shared photo only while a removed listing names it**, decided by the controller on
    2026-11-08 (open question 2). That is Task 8's rule; the app never did more.
18. **Bodies and answers** (Task 8 of the server part, decision 8):
    - Lists come as `{"rows": [...]}` and one gym as `{"gym": …}`. `GymCatalogRows.array(in:key:)` turns either into
      the JSON array the row decoders already read, so `GymCatalogRows` is unchanged.
    - `{id}`, `{confirm_count}`, `{cleared}` and `{admin}` are decoded by small private types.
    - The listing pull's `equipment_items.kind_id` is what `GymListingDTO` already decodes.
19. **`+` in `?place=`.** `ApiClient` already sends `+` as `%2B` (plan 27, Task 1). Probe on a live Worker:
    `?place=a%2Bb` reads `a+b`, and `?place=a+b` reads `a b` (400 `invalid place`). A test pins it.
20. **Errors, code first, then status** (spec section 6):
    - `daily_limit`, `gym_not_shareable`, `photo_missing`, `gym_full`, `photo_in_use`, `unknown_target` and
      `place_taken` reach their cases.
    - `row_rejected` reaches `.noteRefused`, as SQLSTATE 23514 did.
    - Every other `photo_*` code reaches `.photoRefused`.
    - Then: 401 → `.signedOut`; 403 → `.notAllowed` (`.signedOut` without a session); 5xx and 429 → `.offline`;
      anything else → `.rejected(message)`, as 22023 did.
    - A 409 `duplicate` on an upload counts as uploaded.
21. **Uploads send the bytes as `image/jpeg`.**
    - `ApiClient.data` gains a `contentType` parameter, JSON by default.
    - Photo names are checked with `GymPhotoName.isValid` before any request, and lowercased: a name like `../x`
      would take the session's token to another path.
    - Private photos come back through `ApiClient`'s session, which has no URL cache (spec section 7).
22. **Owned photos.** `OwnedPhoto` and the list-remove-list loop move from `SupabaseGymCatalogTransport+Account.swift`
    to `OwnedPhotos.swift`, so the API transport uses them and plan 30 can delete the Supabase file alone. Each photo
    is one `DELETE` on the API.
23. **The server move and the shared catalogue** (plan 27 left it to plan 28). The catalogue's cache names the old
    server's rows. The move now:
    - turns the user's own shared listings, and those still waiting to be shared, into "This phone only", keeping their
      photos. They are the user's equipment, and sharing them on the new server is the user's call;
    - clears every maps gym's refresh stamp, so its next open asks the new server. The old gym id stays for that one
      refresh, because that is how `GymCatalogClient` learns the gym is gone. It then drops other people's cached
      listings and hands back their picture files, as when a moderator removes a gym;
    - clears the items' borrowed catalogue pictures, and empties the share outbox, whose rows name the old server's
      ids and the old account.
    Re-sharing automatically was rejected: it would publish on a new server without the user doing anything.
24. **Exercise photos from the Worker.**
    - `PhotoHostingConfig` reads `API_URL` (`ApiConfig`) instead of `SUPABASE_URL`.
    - `SupabaseStoragePhotoProvider` becomes `HostedPhotoProvider`, at `<API_URL>/photos/exercises/`.
    - `scripts/upload-photos.mjs` takes `WORKER_STATE`, so the photo E2E fills the throwaway test Worker's R2 and never
      the dev data.
25. **The parked suites come back** with the same names and checks, on the Worker:
    - Sign-in is plan 27's email accounts.
    - Photos are a real JPEG start (the server checks the bytes; Storage didn't).
    - "Anonymous" reads become another account's reads, plus a check that signed out is refused.
    - Admins are made by a trigger that `scripts/test-sync-integration.sh` adds to the throwaway D1 only, as the
      Supabase script did for `sync-admin-*@test.local`. Probe: a trigger added with `wrangler d1 execute --local`
      to a running Worker's D1 made the next such sign-up an admin.
    - The E2E's search of D1 uses `instr()`, because D1 refuses LIKE patterns over 50 bytes and a marker is longer.
26. **Checked while writing:** Tasks 11–14 and 16 were applied to a scratch copy of `ios/Packages` at plan 27's head
    (`509cbf1`), never committed. Results:
    - GymSync: `Test run with 207 tests in 27 suites passed`.
    - GymData: 365 tests in 50 suites. The one failure was `LibraryTests`, which needs the app's `exercises.json` beside
      the copy, as plan 27 found.
    - All 39 integration tests passed against a throwaway `wrangler dev --local` of this plan's server, the five
      ported suites and the new move test among them. Of those 39, 15 are plan 27's and 24 are this plan's.
    - Not run ahead: Task 15 (the app target) and the scripts of Tasks 16–17 end to end. Their SQL was run on a
      local D1.

### File map (iOS)

| File | Change |
|---|---|
| `ios/Packages/GymSync/Sources/GymSync/ApiClient.swift` | `contentType` on `data` |
| `…/GymCatalogErrors.swift` | Read `ApiError` |
| `…/OwnedPhotos.swift`, `…/SupabaseGymCatalogTransport+Account.swift` | The owned-photo helpers, shared |
| `…/GymCatalogRows+Api.swift` | `{"rows"}` and `{"gym"}` as the decoders' arrays |
| `…/ApiGymCatalogTransport.swift`, `…/ApiGymCatalogTransport+Photos.swift` | Create |
| `…/ApiSyncTransport.swift`, `…/ApiSyncTransport+Gyms.swift` | `servesGyms`; gyms, listings, private photos |
| `ios/Packages/GymSync/Tests/GymSyncTests/GymCatalogErrorsApiTests.swift`, `ApiGymCatalogTransportTests.swift`, `ApiSyncTransportGymTests.swift` | Create |
| `…/GymSyncTests/GymPhotoRemovalTests.swift`, `ApiSyncTransportTests.swift` | Follow the moves |
| `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+ServerMove.swift` | `forgetOldCatalogue` |
| `ios/Packages/GymData/Tests/GymDataTests/SyncStoreServerMoveCatalogueTests.swift` | Create |
| `ios/GymRollins/App/AppEnvironment+GymCatalog.swift` | The catalogue on the API |
| `ios/GymRollins/Features/Media/*` (`PhotoHosting`, `HostedPhotoProvider`, …) | Exercise photos from the Worker |
| `ios/GymRollinsTests/StoragePhotoHostingTests.swift`, `StoragePhotoIntegrationTests.swift`, … | Follow the rename |
| `…/GymSyncIntegrationTests/GymIntegrationSupport.swift`, `IntegrationSupport.swift`, the five gym suites | On the Worker |
| `scripts/test-sync-integration.sh`, `test-gym-e2e.sh`, `test-photo-hosting.sh`, `upload-photos.mjs`, `test-all.sh`, `server-move-check.sh` | The Worker |
| `docs/media/README.md` | Hosting on the Worker |

### How to run things (iOS)

As plan 27's "How to run things". Plan 27 ended at `Test run with 190 tests in 24 suites passed` for GymSyncTests and
363 tests in 49 suites for GymData; each task below gives the new counts. If plan 27's own counts differ, add these
tasks' tests to them: 4, 9, 4 and 2.

---

### Task 11: The API's errors in the catalogue, photo bodies, and owned photos

**Files:**
- Modify: `ios/Packages/GymSync/Sources/GymSync/ApiClient.swift`, `GymCatalogErrors.swift`,
  `SupabaseGymCatalogTransport+Account.swift`
- Create: `ios/Packages/GymSync/Sources/GymSync/OwnedPhotos.swift`
- Modify: `ios/Packages/GymSync/Tests/GymSyncTests/GymPhotoRemovalTests.swift`
- Test: `ios/Packages/GymSync/Tests/GymSyncTests/GymCatalogErrorsApiTests.swift`

- [ ] **Step 1: Write the failing tests**

`ios/Packages/GymSync/Tests/GymSyncTests/GymCatalogErrorsApiTests.swift`:

```swift
import Foundation
import GymData
import Testing
@testable import GymSync

/// `GymCatalogErrors.map` reading the API's errors (spec section 6): the code first, then the status, to the cases the
/// Postgres errors reached, so the app shows the same messages.
@Suite struct GymCatalogErrorsApiTests {
    private func api(_ status: Int, _ code: String, _ message: String = "The server's words.") -> ApiError {
        ApiError(status: status, code: code, message: message)
    }

    @Test func eachRefusalCodeReachesItsCase() {
        let cases: [(ApiError, GymCatalogError)] = [
            (api(422, "daily_limit"), .dailyLimit), (api(422, "gym_not_shareable"), .gymNotShareable),
            (api(422, "photo_missing"), .photoMissing), (api(422, "gym_full"), .gymFull),
            (api(422, "photo_in_use"), .photoInUse), (api(422, "unknown_target"), .unknownTarget),
            (api(422, "place_taken"), .placeTaken), (api(422, "row_rejected"), .noteRefused),
        ]
        for (error, expected) in cases {
            #expect(GymCatalogErrors.map(error, hasSession: true) == expected, "\(error.code)")
        }
    }

    @Test func everyPhotoRuleIsOneRefusal() {
        let codes = ["photo_daily_limit", "photo_name_in_use", "photo_bad_name", "photo_not_jpeg", "photo_owner_missing"]
        for code in codes {
            #expect(GymCatalogErrors.map(api(422, code), hasSession: true) == .photoRefused, "\(code)")
        }
    }

    @Test func theStatusDecidesTheRest() {
        #expect(GymCatalogErrors.map(api(401, "signed_out"), hasSession: true) == .signedOut)
        #expect(GymCatalogErrors.map(api(403, "not_allowed"), hasSession: true) == .notAllowed)
        #expect(GymCatalogErrors.map(api(403, "not_allowed"), hasSession: false) == .signedOut)
        for status in [429, 500, 503] {
            #expect(GymCatalogErrors.map(api(status, "busy"), hasSession: true) == .offline, "\(status)")
        }
        #expect(GymCatalogErrors.map(api(400, "bad_request", "invalid loads"), hasSession: true)
            == .rejected("invalid loads"))
        #expect(GymCatalogErrors.map(api(422, "unknown_listing", "unknown listing"), hasSession: true)
            == .rejected("unknown listing"))
        #expect(GymCatalogErrors.map(api(413, "too_large", "A photo is at most 1 MB."), hasSession: true)
            == .rejected("A photo is at most 1 MB."))
    }

    @Test func aNetworkFailureIsStillOffline() {
        #expect(GymCatalogErrors.map(URLError(.notConnectedToInternet), hasSession: true) == .offline)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd ios/Packages/GymSync && swift test --filter GymCatalogErrorsApiTests`
Expected: FAIL. An `ApiError` reaches `.rejected(…)` for every code.

- [ ] **Step 3: Let `ApiClient` send a body that isn't JSON**

In `ApiClient.swift`, replace

```swift
    /// One exchange; the body and response of a 2xx answer.
    func data(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
              bearer: Bearer = .stored) async throws -> (body: Data, response: HTTPURLResponse) {
```

with

```swift
    /// One exchange; the body and response of a 2xx answer. `contentType` names `body`: JSON, or `image/jpeg` for a
    /// photo upload.
    func data(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
              contentType: String = "application/json",
              bearer: Bearer = .stored) async throws -> (body: Data, response: HTTPURLResponse) {
```

and, in its body, `request.setValue("application/json", forHTTPHeaderField: "Content-Type")` with
`request.setValue(contentType, forHTTPHeaderField: "Content-Type")`.

- [ ] **Step 4: Share the owned-photo helpers**

`ios/Packages/GymSync/Sources/GymSync/OwnedPhotos.swift`:

```swift
import Foundation
import GymData

/// An object the caller owns in one of the gym buckets, as `GET /v1/photos/mine` (and `my_gym_photos()` before it)
/// lists it.
struct OwnedPhoto: Decodable, Equatable, Hashable {
    let bucketId: String
    let name: String

    enum CodingKeys: String, CodingKey { case bucketId = "bucket_id", name }
}

/// Removing every photo an account owns, before the account is deleted: list, remove, list again until nothing is
/// left. Shared by the API's catalogue transport and, until plan 30 deletes it, the Supabase one.
enum OwnedPhotos {
    /// A remove call takes a few names at a time, so each request stays small.
    static let removeBatch = 100
    /// A list is capped (PostgREST's `max_rows`, the API's 1,000 rows), so a user with more is listed again after each
    /// pass.
    static let maxPhotoPasses = 20

    /// Lists, removes, and lists again until nothing is left. The same objects twice in a row mean the server is not
    /// removing them, and `maxPasses` bounds a user whose photos keep appearing; either ends in a refusal instead of
    /// a loop.
    static func removeEverything(maxPasses: Int = maxPhotoPasses, batchSize: Int = removeBatch,
                                 list: () async throws -> [OwnedPhoto],
                                 remove: (_ bucket: String, _ names: [String]) async throws -> Void) async throws {
        var previous: Set<OwnedPhoto> = []
        for _ in 0..<maxPasses {
            let photos = try await list()
            if photos.isEmpty { return }
            guard Set(photos) != previous else { throw GymCatalogError.rejected("photos remain") }
            previous = Set(photos)
            try await removeAll(photos, batchSize: batchSize, remove: remove)
        }
        throw GymCatalogError.rejected("photos remain")
    }

    static func list(from data: Data) throws -> [OwnedPhoto] {
        do {
            return try JSONDecoder().decode([OwnedPhoto].self, from: data)
        } catch {
            throw GymCatalogError.rejected("unreadable photo list")
        }
    }

    static func removeAll(_ photos: [OwnedPhoto], batchSize: Int = removeBatch,
                          remove: (_ bucket: String, _ names: [String]) async throws -> Void) async throws {
        var buckets: [String] = []
        for photo in photos where !buckets.contains(photo.bucketId) { buckets.append(photo.bucketId) }
        for bucket in buckets {
            let names = photos.filter { $0.bucketId == bucket }.map(\.name)
            for start in stride(from: 0, to: names.count, by: batchSize) {
                try await remove(bucket, Array(names[start..<min(start + batchSize, names.count)]))
            }
        }
    }
}
```

Replace `ios/Packages/GymSync/Sources/GymSync/SupabaseGymCatalogTransport+Account.swift` with:

```swift
import Foundation
import GymData
import Supabase

extension SupabaseGymCatalogTransport {
    /// Removes every photo the caller owns, listed on a listing or not (`my_gym_photos()` goes by owner). Stops at the
    /// first real failure. An object that is already gone isn't one: Storage just leaves it out of its answer.
    public func deleteAllPhotos() async throws {
        guard client.auth.currentSession != nil else { throw GymCatalogError.signedOut }
        try await OwnedPhotos.removeEverything(list: {
            let data = try await call { try await client.rpc("my_gym_photos").execute().data }
            return try OwnedPhotos.list(from: data)
        }, remove: { bucket, names in
            _ = try await call { try await client.storage.from(bucket).remove(paths: names) }
        })
    }

    /// Clears the photo names from the caller's own listings, so they don't name objects `deleteAllPhotos` is about to
    /// remove. Nothing else changes.
    public func detachAllPhotos() async throws {
        guard client.auth.currentSession != nil else { throw GymCatalogError.signedOut }
        _ = try await call { try await client.rpc("detach_my_gym_photos").execute().data }
    }
}
```

Point the existing tests at the new home:

```bash
cd ios/Packages/GymSync/Tests/GymSyncTests
sed -i '' -e 's/SupabaseGymCatalogTransport\.removeAll/OwnedPhotos.removeAll/g' \
  -e 's/SupabaseGymCatalogTransport\.removeEverything/OwnedPhotos.removeEverything/g' \
  -e 's/SupabaseGymCatalogTransport\.ownedPhotos(from:/OwnedPhotos.list(from:/g' GymPhotoRemovalTests.swift
```

- [ ] **Step 5: Read `ApiError` in `GymCatalogErrors`**

Replace `ios/Packages/GymSync/Sources/GymSync/GymCatalogErrors.swift` with:

```swift
import Foundation
import GymData
import Supabase

/// Turns what the API (and, until plan 30, PostgREST, Storage and Supabase Auth) throws into the few cases
/// `ShareOutbox` reacts to: offline and signed-out stop the queue, the rest settle one row. The server's own words are the function's `raise exception` messages.
enum GymCatalogErrors {
    private static let authCodes: Set<String> = ["PGRST301", "PGRST302", "PGRST303"]
    /// PostgREST's own "the database isn't reachable or is busy" answers, and Postgres classes 08 (connection) and
    /// 53 (resources, e.g. too many connections).
    /// What the bucket trigger raises (`guard_gym_photo`): the daily photo limit, a name a listing already uses, and
    /// names, types and owners that aren't allowed. A Storage version may show the message or only "row-level security".
    private static let photoRefusals: Set<String> = [
        "photo_daily_limit", "photo_name_in_use", "photo_bad_name", "photo_not_jpeg", "photo_immutable",
        "photo_owner_missing",
    ]
    private static let busyCodes: Set<String> = ["PGRST000", "PGRST001", "PGRST002", "PGRST003"]

    /// `hasSession` matters for 42501: with no session the caller is signed out; with one, the server refused this
    /// row (not allowed here), and the queue goes on with the next.
    static func map(_ error: Error, hasSession: Bool = false) -> GymCatalogError {
        switch error {
        case let known as GymCatalogError: known
        case let failure as ApiError: map(api: failure, hasSession: hasSession)
        case let failure as PostgrestError: map(message: failure.message, code: failure.code, hasSession: hasSession)
        case let failure as StorageError: mapStorage(failure)
        case is AuthError: .signedOut
        case let failure as HTTPError: map(status: failure.response.statusCode, text: failure.localizedDescription)
        case _ where AuthFailure.isNetwork(error): .offline
        default: .rejected(error.localizedDescription)
        }
    }

    /// Storage answers HTTP 400 for both a repeated name and a policy refusal; only the body tells them apart.
    static func isDuplicateUpload(_ error: StorageError) -> Bool {
        error.statusCode == "409" || error.error == "Duplicate"
    }

    /// A busy or overloaded server is a reason to try again later, not a verdict on the row.
    static func isTemporary(status: Int) -> Bool { status == 429 || (500...599).contains(status) }

    private static func map(status: Int, text: String) -> GymCatalogError {
        if status == 401 { return .signedOut }
        return isTemporary(status: status) ? .offline : .rejected(text)
    }

    private static func map(message: String, code: String?, hasSession: Bool) -> GymCatalogError {
        switch message {
        case "daily_limit": return .dailyLimit
        case "gym_not_shareable": return .gymNotShareable
        case "photo_missing": return .photoMissing
        case "gym_full": return .gymFull
        case "photo_in_use": return .photoInUse
        case "unknown target": return .unknownTarget
        case "place_taken": return .placeTaken
        case _ where photoRefusals.contains(message): return .photoRefused
        default: break
        }
        if let code {
            if authCodes.contains(code) { return .signedOut }
            // `reports.note` failed its check: control or invisible characters.
            if code == "23514" { return .noteRefused }
            // The item a share named was deleted a moment before (its only other user closed their account). The next
            // try finds or creates the item again, so this is a retry, not a verdict on the row.
            if code == "23503" { return .offline }
            if code == "42501" { return hasSession ? .notAllowed : .signedOut }
            if busyCodes.contains(code) || code.hasPrefix("08") || code.hasPrefix("53") { return .offline }
        }
        return .rejected(message)
    }

    /// The API's refusals (server/src/gyms/refusals.ts, spec section 6): the code first, then the status. The codes are
    /// the strings the Postgres functions raised, so each reaches the same case, and the app the same message.
    private static func map(api failure: ApiError, hasSession: Bool) -> GymCatalogError {
        switch failure.code {
        case "daily_limit": return .dailyLimit
        case "gym_not_shareable": return .gymNotShareable
        case "photo_missing": return .photoMissing
        case "gym_full": return .gymFull
        case "photo_in_use": return .photoInUse
        case "unknown_target": return .unknownTarget
        case "place_taken": return .placeTaken
        // A CHECK or clean_text refused the text (23514): on a report, its note.
        case "row_rejected": return .noteRefused
        case _ where failure.code.hasPrefix("photo_"): return .photoRefused
        default: break
        }
        switch failure.status {
        case 401: return .signedOut
        case 403: return hasSession ? .notAllowed : .signedOut
        case _ where failure.isTemporary: return .offline
        default: return .rejected(failure.message)
        }
    }

    /// The trigger on the buckets refuses an upload with a row-level-security error: the daily photo limit, or a
    /// name a listing already uses. Storage shows only that, as HTTP 400 `AccessDenied`, so every such refusal is one
    /// answer for the row. A repeated name (409 `Duplicate`) is told apart before this runs.
    private static func mapStorage(_ error: StorageError) -> GymCatalogError {
        if error.statusCode == "401" { return .signedOut }
        if let status = error.statusCode.flatMap(Int.init), isTemporary(status: status) { return .offline }
        if error.error == "AccessDenied" || photoRefusals.contains(error.message)
            || error.message.localizedCaseInsensitiveContains("row-level security") {
            return .photoRefused
        }
        return .rejected(error.message)
    }
}
```

What changed:
- the type's doc comment;
- `case let failure as ApiError: map(api: failure, hasSession: hasSession)` as the second case;
- the new `map(api:hasSession:)`.
The Supabase mapping stays until plan 30.

- [ ] **Step 6: Run the tests**

Run: `cd ios/Packages/GymSync && swift test --filter GymSyncTests`
Expected: `Test run with 194 tests in 25 suites passed`.

- [ ] **Step 7: Commit**

```bash
git add ios/Packages/GymSync
git commit -m "feat(sync): the catalogue's errors read ApiError; photo bodies; owned photos shared"
```

- [ ] **Step 8: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** spec section 6, and decisions 20 and 22. Every code in `server/src/gyms/refusals.ts` reaches
   the case its Postgres message reached in the old `map(message:code:)`.
2. **Quality:** the `code-reviewer` agent, then the `swift` skill's review checklist.

---

### Task 12: `ApiGymCatalogTransport`

**Files:**
- Create: `ios/Packages/GymSync/Sources/GymSync/GymCatalogRows+Api.swift`, `ApiGymCatalogTransport.swift`,
  `ApiGymCatalogTransport+Photos.swift`
- Test: `ios/Packages/GymSync/Tests/GymSyncTests/ApiGymCatalogTransportTests.swift`

- [ ] **Step 1: Write the failing tests**

`ios/Packages/GymSync/Tests/GymSyncTests/ApiGymCatalogTransportTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// `ApiGymCatalogTransport` against a stub of the catalogue, moderation and photo routes: the paths, queries and bodies
/// of server/src/gyms, src/moderation and src/photos, and their answers.
@Suite struct ApiGymCatalogTransportTests {
    private let gymId = UUID(uuidString: "6F1C2A3B-0000-4000-8000-000000000001")!
    private let listingId = UUID(uuidString: "6F1C2A3B-0000-4000-8000-000000000002")!
    private let photo = "6f1c2a3b-0000-4000-8000-0000000000aa.jpg"
    /// The same name as the phone may hold it: an uppercase UUID (the server keeps names lowercase).
    private var upperPhoto: String { photo.dropLast(4).uppercased() + ".jpg" }

    private func signedIn(_ server: StubServer) -> ApiGymCatalogTransport {
        let session = StoredSession(token: "token-1", userId: UUID(), email: nil)
        return ApiGymCatalogTransport(api: server.client(sessions: InMemorySessionStore(session)))
    }

    private func body(_ request: SeenRequest?) -> [String: Any] { ((try? request?.json()) as? [String: Any]) ?? [:] }

    private var listingJSON: String {
        #"{"id": "\#(listingId)", "gym_id": "\#(gymId)", "item_id": "\#(UUID())", "kind_id": "cable-station", "#
            + #""brand": null, "model": null, "photo_path": "\#(photo)", "loads": {"type": "none"}, "quantity": 1, "#
            + #""notes": null, "status": "active", "confirm_count": 2, "is_mine": true, "confirmed_by_me": false}"#
    }

    @Test func aPublicGymIsAskedForByItsPlaceWithPlusSentAsPercent2B() async throws {
        let place = "ChIJ+ab/c="
        let server = StubServer { request in
            request.query["place"] == place
                ? .json(200, #"{"gym": {"id": "\#(gymId)", "name": "Iron Works", "address": null, "latitude": 52.5, "#
                    + #""longitude": 13.4, "maps_place_id": "\#(place)", "status": "active", "is_mine": false}}"#)
                : .json(200, #"{"gym": null}"#)
        }
        let found = try await signedIn(server).publicGym(mapsPlaceId: place)
        #expect(found == RemoteGym(id: gymId, name: "Iron Works", address: nil, latitude: 52.5, longitude: 13.4,
                                   mapsPlaceId: place))
        let request = try #require(server.requests.first)
        #expect(request.path == "/v1/gyms/public")
        #expect(request.url.absoluteString.contains("%2B") && !request.url.absoluteString.contains("+"))
        #expect(try await signedIn(server).publicGym(mapsPlaceId: "elsewhere") == nil)
    }

    @Test func listingsAreReadInPagesOfFiveHundredUntilAShortOne() async throws {
        let server = StubServer { _ in .json(200, #"{"rows": [\#(listingJSON)]}"#) }
        let read = try await signedIn(server).publicListings(gymId: gymId)
        #expect(read.listings.map(\.id) == [listingId])
        #expect(read.listings.first?.isMine == true && read.listings.first?.confirmCount == 2)
        #expect(read.isComplete)
        let request = try #require(server.requests.first)
        #expect(request.path == "/v1/gyms/\(gymId.uuidString.lowercased())/listings")
        #expect(request.query == ["offset": "0", "limit": "500"])

        var offsets: [Int] = []
        let full = try JSONSerialization.data(withJSONObject: [[:], [:]])
        let capped = try await ApiGymCatalogTransport.readListings(pageSize: 2, maxPages: 2) { start in
            offsets.append(start)
            return full
        }
        #expect(offsets == [0, 2])
        #expect(capped.capped && capped.skipped == 4)
    }

    @Test func itemsAndTheQueueAreReadFromRows() async throws {
        let server = StubServer { request in
            switch request.path {
            case "/v1/items":
                return .json(200, #"{"rows": [{"id": "\#(UUID())", "kind_id": "\#(request.query["kind"] ?? "")", "#
                    + #""brand": "Acme", "model": null, "photo_path": null, "photo_listing_id": null, "#
                    + #""gym_count": 3}]}"#)
            default:
                return .json(200, #"{"rows": [{"target_type": "listing", "target_id": "\#(listingId)", "#
                    + #""title": "Acme", "photo_path": null, "report_count": 3, "reasons": {"spam": 3}, "notes": [], "#
                    + #""status": "flagged", "#
                    + #""address": "Iron Works", "listing_notes": null}]}"#)
            }
        }
        let items = try await signedIn(server).publicItems(kindId: "cable-station")
        #expect(items.map(\.kindId) == ["cable-station"] && items.first?.gymCount == 3)
        let queue = try await signedIn(server).moderationQueue()
        #expect(queue.map(\.targetId) == [listingId] && queue.first?.reportCount == 3)
        #expect(server.requests.map(\.path) == ["/v1/items", "/v1/admin/queue"])
    }

    @Test func writesSendTheirArgumentsAsSnakeCaseBodiesAndReadObjectAnswers() async throws {
        let server = StubServer { request in
            switch request.path {
            case "/v1/gyms/find-or-create": return .json(200, #"{"id": "\#(gymId)"}"#)
            case "/v1/listings/share": return .json(200, #"{"status": "created", "listing_id": "\#(listingId)"}"#)
            case "/v1/blocks" where request.method == "DELETE": return .json(200, #"{"cleared": 2}"#)
            case "/v1/blocks", "/v1/admin/photo-deleted": return StubAnswer(status: 204, headers: [:], body: Data())
            case "/v1/reports": return .json(200, #"{"status": "already"}"#)
            case "/v1/admin/moderate": return .json(200, #"{"status": "removed", "photo_path": "\#(photo)"}"#)
            default: return .json(200, #"{"confirm_count": 4}"#)
            }
        }
        let transport = signedIn(server)
        let created = try await transport.findOrCreateGym(mapsPlaceId: "p-1", name: "Iron Works", address: nil,
                                                          latitude: 52.5, longitude: nil)
        #expect(created == gymId)
        let share = ShareRequest(listingId: listingId, gymId: gymId, kindId: "cable-station", brand: "Acme", model: nil,
                                 loads: .stack(maxKg: 90, stepKg: 5), quantity: 2, notes: "by the door",
                                 photoPath: upperPhoto, forceNew: true)
        #expect(try await transport.share(share) == .created(listingId))
        #expect(try await transport.confirm(listingId: listingId) == 4)
        try await transport.report(targetType: .listing, targetId: listingId, reason: .personInPhoto, note: "a face")
        try await transport.blockAuthor(targetType: .gym, targetId: gymId)
        #expect(try await transport.unblockAll() == 2)
        #expect(try await transport.moderate(targetType: .listing, targetId: listingId, action: .remove) == photo)
        try await transport.moderationPhotoDeleted(path: photo)

        let seen = server.requests
        #expect(seen.map { "\($0.method) \($0.path)" } == [
            "POST /v1/gyms/find-or-create", "POST /v1/listings/share",
            "POST /v1/listings/\(listingId.uuidString.lowercased())/confirm", "POST /v1/reports", "POST /v1/blocks",
            "DELETE /v1/blocks", "POST /v1/admin/moderate", "POST /v1/admin/photo-deleted",
        ])
        #expect(body(seen[0])["maps_place_id"] as? String == "p-1" && body(seen[0])["latitude"] as? Double == 52.5)
        let shared = body(seen[1])
        #expect(shared["listing_id"] as? String == listingId.uuidString.lowercased())
        #expect(shared["gym_id"] as? String == gymId.uuidString.lowercased())
        #expect(shared["photo_path"] as? String == photo && shared["force_new"] as? Bool == true)
        #expect((shared["loads"] as? [String: Any])?["maxKg"] as? Double == 90)
        #expect(body(seen[3])["target_type"] as? String == "listing")
        #expect(body(seen[3])["reason"] as? String == "person-in-photo")
        #expect(body(seen[4])["target_id"] as? String == gymId.uuidString.lowercased())
        #expect(body(seen[6])["action"] as? String == "remove")
        #expect(body(seen[7])["path"] as? String == photo)
    }

    @Test func isAdminAsksOnlyWithASession() async throws {
        let server = StubServer { _ in .json(200, #"{"admin": true}"#) }
        #expect(try await ApiGymCatalogTransport(api: server.client()).isAdmin() == false)
        #expect(server.requests.isEmpty)
        #expect(try await signedIn(server).isAdmin())
        #expect(server.requests.map(\.path) == ["/v1/admin/me"])
    }

    @Test func aSharedPhotoGoesUpAsJpegAndARepeatIsDone() async throws {
        let server = StubServer { request in
            request.headers["Content-Type"] == "image/jpeg"
                ? .json(409, #"{"error": {"code": "duplicate", "message": "Already uploaded."}}"#)
                : .json(400, #"{"error": {"code": "bad_request", "message": "wrong type"}}"#)
        }
        let transport = signedIn(server)
        #expect(try await transport.uploadSharedPhoto(Data([0xFF, 0xD8, 0xFF]), name: upperPhoto) == photo)
        let request = try #require(server.requests.first)
        #expect(request.method == "PUT" && request.path == "/v1/photos/shared/\(photo)")
        #expect(request.body == Data([0xFF, 0xD8, 0xFF]))
        await #expect(throws: GymCatalogError.rejected("not a photo name")) {
            _ = try await transport.uploadSharedPhoto(Data(), name: "../secret.jpg")
        }
        await #expect(throws: GymCatalogError.signedOut) {
            _ = try await ApiGymCatalogTransport(api: server.client()).uploadSharedPhoto(Data(), name: photo)
        }
        #expect(server.requests.count == 1)
    }

    @Test func deletingAllPhotosListsRemovesAndListsAgain() async throws {
        let names = ["gym-photos": "6f1c2a3b-0000-4000-8000-0000000000b1.jpg",
                     "gym-photos-private": "6f1c2a3b-0000-4000-8000-0000000000b2.jpg"]
        let remaining = Remaining(names)
        let server = StubServer { request in
            if request.method == "GET" {
                let rows = remaining.value.map { #"{"bucket_id": "\#($0.key)", "name": "\#($0.value)"}"# }
                return .json(200, #"{"rows": [\#(rows.joined(separator: ","))]}"#)
            }
            remaining.remove(request.path)
            return StubAnswer(status: 204, headers: [:], body: Data())
        }
        try await signedIn(server).deleteAllPhotos()
        let deletes = server.requests.filter { $0.method == "DELETE" }.map(\.path).sorted()
        #expect(deletes == ["/v1/photos/private/\(names["gym-photos-private"]!)",
                            "/v1/photos/shared/\(names["gym-photos"]!)"])
        #expect(server.requests.filter { $0.method == "GET" }.count == 2)
        try await signedIn(server).detachAllPhotos()
        #expect(server.requests.last.map { "\($0.method) \($0.path)" } == "POST /v1/photos/detach")
    }

    @Test func refusalsReachTheQueuesCases() async throws {
        let answers: [(StubAnswer, GymCatalogError)] = [
            (.json(401, #"{"error": {"code": "signed_out", "message": "Sign in required."}}"#), .signedOut),
            (.json(422, #"{"error": {"code": "daily_limit", "message": "You've shared a lot today."}}"#), .dailyLimit),
            (.json(503, #"{"error": {"code": "try_again", "message": "Try again."}}"#), .offline),
        ]
        for (answer, expected) in answers {
            let server = StubServer { _ in answer }
            await #expect(throws: expected) { _ = try await signedIn(server).confirm(listingId: listingId) }
        }
    }

    @Test func aPublicPhotoIsTheWorkersPublicRoute() throws {
        let server = StubServer { _ in .json(200, "{}") }
        let url = try #require(signedIn(server).publicPhotoURL(path: upperPhoto))
        #expect(url.absoluteString == "\(server.baseURL.absoluteString)/photos/shared/\(photo)")
        #expect(signedIn(server).publicPhotoURL(path: "../x.jpg") == nil)
    }
}

/// The photos a stub server still holds, by bucket.
private final class Remaining: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String]
    init(_ names: [String: String]) { self.names = names }
    var value: [String: String] { lock.withLock { names } }
    func remove(_ path: String) { lock.withLock { names = names.filter { !path.hasSuffix($0.value) } } }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd ios/Packages/GymSync && swift test --filter ApiGymCatalogTransportTests`
Expected: FAIL to build: `cannot find 'ApiGymCatalogTransport' in scope`.

- [ ] **Step 3: Read the API's answers as the row decoders' arrays**

`ios/Packages/GymSync/Sources/GymSync/GymCatalogRows+Api.swift`:

```swift
import Foundation
import GymData

extension GymCatalogRows {
    /// The rows of an API answer as the row decoders read them, a JSON array: the list under `key`
    /// (`{"rows": [...]}`), or a one-row list for an object answer (`{"gym": {...}}`), empty when it is null.
    static func array(in data: Data, key: String) throws -> Data {
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let value = answer[key]
        else { throw GymCatalogError.rejected("unreadable response") }
        let rows: [Any] = (value as? [Any]) ?? (value is NSNull ? [] : [value])
        return try JSONSerialization.data(withJSONObject: rows)
    }
}
```

- [ ] **Step 4: Write the transport**

`ios/Packages/GymSync/Sources/GymSync/ApiGymCatalogTransport.swift`:

```swift
import Foundation
import GymCore
import GymData

/// `GymCatalogTransport` over the API: the shared catalogue (`/v1/gyms`, `/v1/items`, `/v1/listings`), moderation
/// (`/v1/reports`, `/v1/blocks`, `/v1/admin`) and shared photos (`/v1/photos`, read at `/photos/shared`); see
/// server/src/gyms, src/moderation and src/photos. Every call but the public photo URL needs the app session: a
/// signed-out phone hears `.signedOut`, reads included (spec section 3; Supabase let the anon key read the views).
public struct ApiGymCatalogTransport: GymCatalogTransport {
    /// A gym holds at most `DomainLimits.gymActiveListingsMax` (300) active listings, so one page covers it; two pages
    /// is the most this reads, and a gym past that is reported as partial instead of looped on.
    static let pageSize = 500
    static let maxPages = 2

    let api: ApiClient

    public init(api: ApiClient) { self.api = api }

    var hasSession: Bool { api.sessions.load() != nil }

    // MARK: Reads

    public func publicGym(mapsPlaceId: String) async throws -> RemoteGym? {
        // ApiClient sends "+" as %2B: a bare "+" in a query is a space to the server, and place ids can hold one.
        let body = try await call {
            try await api.data("GET", "/v1/gyms/public", query: [URLQueryItem(name: "place", value: mapsPlaceId)]).body
        }
        return try GymCatalogRows.gyms(from: GymCatalogRows.array(in: body, key: "gym")).rows.first
    }

    public func publicListings(gymId: UUID) async throws -> PublicListings {
        try await Self.readListings { start in
            let query = [URLQueryItem(name: "offset", value: String(start)),
                         URLQueryItem(name: "limit", value: String(Self.pageSize))]
            let path = "/v1/gyms/\(Self.text(gymId))/listings"
            let body = try await call { try await api.data("GET", path, query: query).body }
            return try GymCatalogRows.array(in: body, key: "rows")
        }
    }

    /// Reads pages until one is short or `maxPages` is used up; the second case comes back marked as capped.
    static func readListings(pageSize: Int = Self.pageSize, maxPages: Int = Self.maxPages,
                             page: (Int) async throws -> Data) async throws -> PublicListings {
        var found: [RemoteListing] = []
        var skipped = 0
        var start = 0
        for _ in 0..<maxPages {
            let data = try await page(start)
            let decoded = try GymCatalogRows.listings(from: data)
            found += decoded.rows
            skipped += decoded.skipped
            let count = GymCatalogRows.rawCount(of: data)
            if count < pageSize { return PublicListings(listings: found, skipped: skipped) }
            start += count
        }
        return PublicListings(listings: found, skipped: skipped, capped: true)
    }

    public func publicItems(kindId: String) async throws -> [RemoteItem] {
        let body = try await call {
            try await api.data("GET", "/v1/items", query: [URLQueryItem(name: "kind", value: kindId)]).body
        }
        return try GymCatalogRows.items(from: GymCatalogRows.array(in: body, key: "rows")).rows
    }

    /// `<API_URL>/photos/shared/<name>`: public and cached, so loading it needs no session.
    public func publicPhotoURL(path: String) -> URL? {
        guard GymPhotoName.isValid(path) else { return nil }
        return api.baseURL.appending(path: "photos/shared/\(path.lowercased())")
    }

    // MARK: Writes

    public func findOrCreateGym(mapsPlaceId: String, name: String, address: String?, latitude: Double?,
                                longitude: Double?) async throws -> UUID {
        let place = Place(mapsPlaceId: mapsPlaceId, name: name, address: address, latitude: latitude,
                          longitude: longitude)
        let answer: IdAnswer = try await call { try await api.post("/v1/gyms/find-or-create", place) }
        return answer.id
    }

    public func share(_ request: ShareRequest) async throws -> ShareResult {
        let body = try await call {
            try await api.data("POST", "/v1/listings/share", body: SyncJSON.encoder.encode(ShareBody(request))).body
        }
        return try GymCatalogRows.shareResult(from: body, gymId: request.gymId)
    }

    public func confirm(listingId: UUID) async throws -> Int {
        let path = "/v1/listings/\(Self.text(listingId))/confirm"
        let answer: ConfirmAnswer = try await call { try await api.post(path, Empty()) }
        return answer.confirmCount
    }

    /// The server answers `{"status": "reported" | "own" | "already"}`; none of them is an error to the queue.
    public func report(targetType: GymTargetType, targetId: UUID, reason: ReportReason, note: String?) async throws {
        let body = ReportBody(targetType: targetType.rawValue, targetId: Self.text(targetId), reason: reason.rawValue,
                              note: note)
        _ = try await call { try await api.data("POST", "/v1/reports", body: SyncJSON.encoder.encode(body)) }
    }

    public func blockAuthor(targetType: GymTargetType, targetId: UUID) async throws {
        let body = Target(targetType: targetType.rawValue, targetId: Self.text(targetId))
        _ = try await call { try await api.data("POST", "/v1/blocks", body: SyncJSON.encoder.encode(body)) }
    }

    public func unblockAll() async throws -> Int {
        let body = try await call { try await api.data("DELETE", "/v1/blocks").body }
        return try Self.decode(Cleared.self, from: body, what: "unblock count").cleared
    }

    // MARK: Moderation

    public func isAdmin() async throws -> Bool {
        guard hasSession else { return false }
        let body = try await call { try await api.data("GET", "/v1/admin/me").body }
        return try Self.decode(AdminAnswer.self, from: body, what: "admin answer").admin
    }

    public func moderationQueue() async throws -> [ModerationEntry] {
        let body = try await call { try await api.data("GET", "/v1/admin/queue").body }
        return try GymCatalogRows.moderation(from: GymCatalogRows.array(in: body, key: "rows")).rows
    }

    public func moderate(targetType: GymTargetType, targetId: UUID, action: ModerationAction) async throws -> String? {
        let body = ModerateBody(targetType: targetType.rawValue, targetId: Self.text(targetId), action: action.rawValue)
        let answer = try await call {
            try await api.data("POST", "/v1/admin/moderate", body: SyncJSON.encoder.encode(body)).body
        }
        return try GymCatalogRows.moderatedPhoto(from: answer)
    }

    public func moderationPhotoDeleted(path: String) async throws {
        let body = PathBody(path: path.lowercased())
        _ = try await call {
            try await api.data("POST", "/v1/admin/photo-deleted", body: SyncJSON.encoder.encode(body))
        }
    }

    // MARK: Helpers

    enum UploadOutcome: Error { case alreadyThere }

    /// Every call's errors as `GymCatalogError`. A 409 `duplicate` is a photo an earlier try uploaded whose answer was
    /// lost; the upload treats it as done.
    func call<R>(_ body: () async throws -> R) async throws -> R {
        do {
            return try await body()
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch let failure as ApiError where failure.status == 409 && failure.code == "duplicate" {
            throw UploadOutcome.alreadyThere
        } catch {
            throw GymCatalogErrors.map(error, hasSession: hasSession)
        }
    }

    static func text(_ id: UUID) -> String { id.uuidString.lowercased() }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T {
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            throw GymCatalogError.rejected("unreadable \(what)")
        }
        return value
    }
}

// MARK: - Bodies and answers (server/src/gyms/share.ts, src/moderation/*.ts)

private struct Empty: Encodable {}

private struct Place: Encodable {
    let mapsPlaceId: String, name: String, address: String?, latitude: Double?, longitude: Double?

    enum CodingKeys: String, CodingKey { case name, address, latitude, longitude, mapsPlaceId = "maps_place_id" }
}

private struct ShareBody: Encodable {
    let listingId: String, gymId: String, kindId: String, brand: String?, model: String?, loads: ListingLoads
    let quantity: Int, notes: String?, photoPath: String?, forceNew: Bool

    init(_ request: ShareRequest) {
        listingId = ApiGymCatalogTransport.text(request.listingId)
        gymId = ApiGymCatalogTransport.text(request.gymId)
        kindId = request.kindId
        brand = request.brand
        model = request.model
        loads = request.loads
        quantity = request.quantity
        notes = request.notes
        photoPath = request.photoPath?.lowercased()
        forceNew = request.forceNew
    }

    enum CodingKeys: String, CodingKey {
        case brand, model, loads, quantity, notes
        case listingId = "listing_id", gymId = "gym_id", kindId = "kind_id", photoPath = "photo_path",
             forceNew = "force_new"
    }
}

private struct Target: Encodable {
    let targetType: String, targetId: String

    enum CodingKeys: String, CodingKey { case targetType = "target_type", targetId = "target_id" }
}

private struct ReportBody: Encodable {
    let targetType: String, targetId: String, reason: String, note: String?

    enum CodingKeys: String, CodingKey { case reason, note, targetType = "target_type", targetId = "target_id" }
}

private struct ModerateBody: Encodable {
    let targetType: String, targetId: String, action: String

    enum CodingKeys: String, CodingKey { case action, targetType = "target_type", targetId = "target_id" }
}

private struct PathBody: Encodable { let path: String }

private struct IdAnswer: Decodable { let id: UUID }

private struct ConfirmAnswer: Decodable {
    let confirmCount: Int

    enum CodingKeys: String, CodingKey { case confirmCount = "confirm_count" }
}

private struct Cleared: Decodable { let cleared: Int }

private struct AdminAnswer: Decodable { let admin: Bool }
```

`ios/Packages/GymSync/Sources/GymSync/ApiGymCatalogTransport+Photos.swift`:

```swift
import Foundation
import GymCore
import GymData

/// Shared photos (`/v1/photos/shared`), and the account's photos in both buckets before it is deleted
/// (`/v1/photos/mine`, `/v1/photos/detach`).
extension ApiGymCatalogTransport {
    /// Uploads to `gym-photos/<name>` as JPEG; a name already uploaded (409) counts as uploaded.
    public func uploadSharedPhoto(_ data: Data, name: String) async throws -> String {
        guard hasSession else { throw GymCatalogError.signedOut }
        let stored = try Self.photoName(name)
        do {
            _ = try await call {
                try await api.data("PUT", "/v1/photos/shared/\(stored)", body: data, contentType: "image/jpeg")
            }
        } catch UploadOutcome.alreadyThere {
            // The same photo, uploaded by an earlier try whose answer was lost.
        }
        return stored
    }

    public func deleteSharedPhoto(path: String) async throws {
        let stored = try Self.photoName(path)
        _ = try await call { try await api.data("DELETE", "/v1/photos/shared/\(stored)") }
    }

    /// Removes every photo the caller owns, listed on a listing or not (`/v1/photos/mine` goes by owner). Stops at the
    /// first real failure. A photo already gone isn't one: the server answers 204 for it.
    public func deleteAllPhotos() async throws {
        guard hasSession else { throw GymCatalogError.signedOut }
        try await OwnedPhotos.removeEverything(list: {
            let body = try await call { try await api.data("GET", "/v1/photos/mine").body }
            return try OwnedPhotos.list(from: GymCatalogRows.array(in: body, key: "rows"))
        }, remove: { bucket, names in
            let folder = bucket == "gym-photos" ? "shared" : "private"
            for name in names {
                _ = try await call { try await api.data("DELETE", "/v1/photos/\(folder)/\(try Self.photoName(name))") }
            }
        })
    }

    /// Clears the photo names from the caller's own listings, so they don't name objects `deleteAllPhotos` is about to
    /// remove. Nothing else changes.
    public func detachAllPhotos() async throws {
        guard hasSession else { throw GymCatalogError.signedOut }
        _ = try await call { try await api.data("POST", "/v1/photos/detach") }
    }

    /// A photo name as the API stores it: a lowercase UUID and `.jpg`. Anything else is refused here, because a name
    /// like `../x` would send the session's token to another path.
    static func photoName(_ name: String) throws -> String {
        guard GymPhotoName.isValid(name) else { throw GymCatalogError.rejected("not a photo name") }
        return name.lowercased()
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `cd ios/Packages/GymSync && swift test --filter GymSyncTests`
Expected: `Test run with 203 tests in 26 suites passed`.

- [ ] **Step 6: Commit**

```bash
git add ios/Packages/GymSync
git commit -m "feat(sync): ApiGymCatalogTransport on the catalogue, moderation and photo routes"
```

- [ ] **Step 7: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** check every path, body, query and answer against the server's routes table and its tests
   (`server/test/catalogue.test.ts`, `share.test.ts`, `moderation.test.ts`, `admin.test.ts`, `photos.test.ts`). The
   server is the source of truth.
2. **Quality:** the `code-reviewer` agent.
3. **Security:** the `security-reviewer` agent:
   - the token goes only to the API's origin;
   - no photo name reaches a URL unchecked;
   - `isAdmin` makes no call without a session.

---

### Task 13: Gyms, listings and private photos in `ApiSyncTransport`

**Files:**
- Modify: `ios/Packages/GymSync/Sources/GymSync/ApiSyncTransport.swift`,
  `ios/Packages/GymSync/Tests/GymSyncTests/ApiSyncTransportTests.swift`
- Create: `ios/Packages/GymSync/Sources/GymSync/ApiSyncTransport+Gyms.swift`
- Test: `ios/Packages/GymSync/Tests/GymSyncTests/ApiSyncTransportGymTests.swift`

- [ ] **Step 1: Write the failing tests**

`ios/Packages/GymSync/Tests/GymSyncTests/ApiSyncTransportGymTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// Private gyms, listings and their photos through `ApiSyncTransport` against a stub of `/v1/sync/gyms`,
/// `/v1/sync/gym-listings` and `/v1/photos/private` (server/src/sync/entities.ts, src/photos/routes.ts).
@Suite struct ApiSyncTransportGymTests {
    private let t0 = SyncDate.parse("2026-11-08T08:00:00.123456Z")!
    private let photo = "6f1c2a3b-0000-4000-8000-0000000000cc.jpg"
    /// The same name as the phone may hold it: an uppercase UUID (the server keeps names lowercase).
    private var upperPhoto: String { photo.dropLast(4).uppercased() + ".jpg" }

    private func rows(_ request: SeenRequest?) -> [[String: Any]] {
        ((try? request?.json()) as? [String: Any])?["rows"] as? [[String: Any]] ?? []
    }

    @Test func gymsAndListingsGoUpAndComeBackOnTheirOwnPaths() async throws {
        let gym = SyncedGym(id: UUID(), name: "Garage", address: nil, latitude: nil, longitude: nil)
        let listingId = UUID()
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("POST", _): return .json(200, #"{"acks": []}"#)
            case (_, "/v1/sync/gym-listings"):
                return .json(200, #"{"rows": [{"id": "\#(listingId)", "gym_id": "\#(gym.id)", "#
                    + #""item_id": "\#(UUID())", "#
                    + #""visibility": "private", "photo_path": null, "loads": {"type": "fixed", "kg": [20, 24]}, "#
                    + #""quantity": 1, "notes": null, "private_brand": "Secret", "private_model": null, "#
                    + #""client_updated_at": "2026-11-08T08:00:00.123456Z", "deleted_at": null, "#
                    + #""updated_at": "2026-11-08T09:00:00.100000Z", "equipment_items": {"kind_id": "dumbbells"}}]}"#)
            default: return .json(200, #"{"rows": []}"#)
            }
        }
        let transport = ApiSyncTransport(api: server.client())
        #expect(transport.servesGyms)
        _ = try await transport.push(gyms: [GymDTO(SyncRow(value: gym, clientUpdatedAt: t0))])
        let pulled = try await transport.pullGymListings(since: nil)
        _ = try await transport.pullGyms(since: nil)

        #expect(server.requests.map { "\($0.method) \($0.path)" } == [
            "POST /v1/sync/gyms", "GET /v1/sync/gym-listings", "GET /v1/sync/gyms",
        ])
        #expect(rows(server.requests.first).first?["visibility"] as? String == "private")
        let listing = try #require(pulled.first?.toDomain())
        #expect(listing.value.kindId == "dumbbells" && listing.value.brand == "Secret")
        #expect(listing.value.loads == .fixed(kg: [20, 24]))
    }

    @Test func aListingWhosePhotoTheServerLacksAsksForTheUploadAgain() async throws {
        let server = StubServer { _ in
            .json(422, #"{"error": {"code": "photo_missing", "message": "That photo isn't uploaded."}}"#)
        }
        let listing = SyncedListing(id: UUID(), gymId: UUID(), kindId: "dumbbells", brand: nil, model: nil,
                                    loads: .fixed(kg: [20]), quantity: 1, notes: nil, photoFile: nil,
                                    remotePhotoPath: photo)
        await #expect(throws: PrivatePhotoMissing.self) {
            _ = try await ApiSyncTransport(api: server.client())
                .push(gymListings: [GymListingDTO(SyncRow(value: listing, clientUpdatedAt: t0))])
        }
    }

    @Test func theCapsRefuseTheRowWithTheAppsWords() async throws {
        let words = "You've reached the limit of gyms on one account."
        let server = StubServer { _ in .json(422, #"{"error": {"code": "too_many_gyms", "message": "\#(words)"}}"#) }
        let gym = SyncedGym(id: UUID(), name: "One more", address: nil, latitude: nil, longitude: nil)
        await #expect(throws: SyncRecordRejected(code: "too_many_gyms", message: words)) {
            let row = GymDTO(SyncRow(value: gym, clientUpdatedAt: t0))
            _ = try await ApiSyncTransport(api: server.client()).push(gyms: [row])
        }
    }

    @Test func aPrivatePhotoGoesUpAsJpegComesBackAndGoes() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let server = StubServer { request in
            switch request.method {
            case "PUT": return .json(409, #"{"error": {"code": "duplicate", "message": "Already uploaded."}}"#)
            case "GET": return StubAnswer(status: 200, headers: ["Content-Type": "image/jpeg"], body: jpeg)
            default: return StubAnswer(status: 204, headers: [:], body: Data())
            }
        }
        let transport = ApiSyncTransport(api: server.client())
        #expect(try await transport.uploadPrivatePhoto(jpeg, name: upperPhoto) == photo)
        #expect(try await transport.downloadPrivatePhoto(path: photo) == jpeg)
        try await transport.deletePrivatePhoto(path: photo)
        let path = "/v1/photos/private/\(photo)"
        #expect(server.requests.map { "\($0.method) \($0.path)" } == ["PUT \(path)", "GET \(path)", "DELETE \(path)"])
        #expect(server.requests.first?.headers["Content-Type"] == "image/jpeg")
        await #expect(throws: URLError.self) { _ = try await transport.downloadPrivatePhoto(path: "../secret.jpg") }
        #expect(server.requests.count == 3)
    }

    @Test func aPrivatePhotoPutAnswering200WithItsNameCountsAsUploaded() async throws {
        let server = StubServer { _ in .json(200, #"{"name": "\#(photo)"}"#) }
        let stored = try await ApiSyncTransport(api: server.client()).uploadPrivatePhoto(Data([1]), name: upperPhoto)
        #expect(stored == photo)
        #expect(server.requests.map { "\($0.method) \($0.path)" } == ["PUT /v1/photos/private/\(photo)"])
    }

    @Test func aPrivatePhotoPutRefusedWithAnotherConflictIsAnError() async throws {
        let server = StubServer { _ in .json(409, #"{"error": {"code": "version_conflict", "message": "No."}}"#) }
        await #expect(throws: ApiError.self) {
            _ = try await ApiSyncTransport(api: server.client()).uploadPrivatePhoto(Data([1]), name: upperPhoto)
        }
    }
}
```

In `ApiSyncTransportTests.swift`, the API now serves gyms: rename `itServesNeitherGymsNorProposalsYet()` to
`itServesGymsButNotProposalsYet()`, and change its first expectation to
`#expect(transport.servesGyms && !transport.servesProposals)`.

- [ ] **Step 2: Run them to see them fail**

Run: `cd ios/Packages/GymSync && swift test --filter 'ApiSyncTransportGymTests|ApiSyncTransportTests'`
Expected: FAIL. `servesGyms` is false, and the gym calls use the protocol's do-nothing defaults.

- [ ] **Step 3: Serve gyms**

In `ApiSyncTransport.swift`:
- replace the doc comment's last paragraph (`/// Gyms, listings, their photos and Claude's proposals aren't on the API until plans 28
  and 29, …` through `… until plan 29.`) with:

```swift
/// Private gyms, their listings and their photos are on the API since plan 28 (`ApiSyncTransport+Gyms.swift`). Claude's
/// proposals aren't until plan 29, so `servesProposals` is false and the engine leaves them out; Claude's last use and
/// grants keep the protocol's defaults (never used, nothing to revoke).
```

- `public var servesGyms: Bool { false }` → `public var servesGyms: Bool { true }`;
- `private func push<Row: Encodable>` → `func push<Row: Encodable>`, and `private func pull<Row: Decodable>` →
  `func pull<Row: Decodable>`, so the extension below can use them.

`ios/Packages/GymSync/Sources/GymSync/ApiSyncTransport+Gyms.swift`:

```swift
import Foundation
import GymCore
import GymData

/// Private gyms and listings (`/v1/sync/gyms`, `/v1/sync/gym-listings`; server/src/sync/entities.ts) and their photos
/// in `gym-photos-private` (`/v1/photos/private/<name>`). The server keeps them to the session's account, stamps the
/// owner and author itself, and nests a pulled listing's kind as `equipment_items.kind_id`, which `GymListingDTO`
/// reads.
extension ApiSyncTransport {
    public func push(gyms: [GymDTO]) async throws -> [RowAck] {
        try await push(gyms, to: "gyms")
    }

    /// A listing whose photo the server doesn't hold as this account's (422 `photo_missing`) throws
    /// `PrivatePhotoMissing`, so the phone uploads it again. The caps (`too_many_gyms`, `too_many_listings`) and refused values come back as
    /// `SyncRecordRejected` with the server's words, which are the app's.
    public func push(gymListings: [GymListingDTO]) async throws -> [RowAck] {
        do {
            return try await push(gymListings, to: "gym-listings")
        } catch let refused as SyncRecordRejected where refused.code == "photo_missing" {
            throw PrivatePhotoMissing()
        }
    }

    public func pullGyms(since: Date?) async throws -> [GymDTO] {
        try await pull("gyms", tiebreak: "id", since: since)
    }

    public func pullGymListings(since: Date?) async throws -> [GymListingDTO] {
        try await pull("gym-listings", tiebreak: "id", since: since)
    }

    /// Uploads as JPEG; a name the caller already uploaded (409 `duplicate`) counts as uploaded; any other 409 is an error.
    public func uploadPrivatePhoto(_ data: Data, name: String) async throws -> String {
        let stored = try Self.privatePhotoPath(name)
        do {
            _ = try await api.data("PUT", stored, body: data, contentType: "image/jpeg")
        } catch let failure as ApiError where failure.status == 409 && failure.code == "duplicate" {
            // The same photo, uploaded by an earlier try whose answer was lost.
        }
        return name.lowercased()
    }

    /// Served to its owner only, never cached: `ApiClient`'s session has no URL cache, and the server says no-store.
    public func downloadPrivatePhoto(path: String) async throws -> Data {
        try await api.data("GET", Self.privatePhotoPath(path)).body
    }

    public func deletePrivatePhoto(path: String) async throws {
        _ = try await api.data("DELETE", Self.privatePhotoPath(path))
    }

    /// `/v1/photos/private/<uuid>.jpg`. Any other name is refused before a request is made: a name like `../x` would
    /// take the session's token to another path.
    static func privatePhotoPath(_ name: String) throws -> String {
        guard GymPhotoName.isValid(name) else { throw URLError(.badURL) }
        return "/v1/photos/private/\(name.lowercased())"
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd ios/Packages/GymSync && swift test --filter GymSyncTests`
Expected: `Test run with 207 tests in 27 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/GymSync
git commit -m "feat(sync): private gyms, listings and their photos on /v1"
```

- [ ] **Step 6: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** decision 18, and plan 27's decision 6 for the refused rows. `photo_missing` is
   `PrivatePhotoMissing`, the caps are `SyncRecordRejected` with the app's words.
2. **Quality:** the `code-reviewer` agent.
3. **Security:** the `security-reviewer` agent. Private photos go to and come from `/v1/photos/private` only, with the
   session and no cache.

---

### Task 14: The server move forgets the old catalogue

**Files:**
- Modify: `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+ServerMove.swift`
- Test: `ios/Packages/GymData/Tests/GymDataTests/SyncStoreServerMoveCatalogueTests.swift`

- [ ] **Step 1: Write the failing tests**

`ios/Packages/GymData/Tests/GymDataTests/SyncStoreServerMoveCatalogueTests.swift`:

```swift
import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// The server move and the shared catalogue's cache (plan 28): the old server's gym ids, cached listings, borrowed
/// pictures and outbox go; the user's own listings stay on the phone, as "This phone only".
@MainActor
@Suite struct SyncStoreServerMoveCatalogueTests {
    let f: SyncFixture
    let transport = FakeGymCatalogTransport()
    init() throws { f = try SyncFixture() }

    private let new = "http://127.0.0.1:8787"
    private var repo: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }

    private func listing(_ id: UUID) throws -> GymListingRecord? {
        try f.context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func gymRecord(_ id: UUID) throws -> GymRecord {
        try #require(try f.context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.id == id })).first)
    }

    private func item(_ id: UUID) throws -> EquipmentItemRecord {
        let items = try f.context.fetch(FetchDescriptor<EquipmentItemRecord>(predicate: #Predicate { $0.id == id }))
        return try #require(items.first)
    }

    private struct OldCatalogue {
        let gym: UUID, own: UUID, waiting: UUID, theirs: UUID, item: UUID
    }

    /// What a phone that used the old server's catalogue holds: a maps gym with the old id, the user's own shared
    /// listing, one still waiting to be shared, someone else's cached listing, an item's borrowed picture, and an
    /// outbox row.
    private func oldCatalogue() throws -> OldCatalogue {
        let gym = try repo.addMapsGym(placeId: "P1", name: "Iron Works", address: nil, latitude: 1, longitude: 2)
        let gymRow = try gymRecord(gym.id)
        gymRow.remoteId = UUID()
        gymRow.catalogRefreshedAt = f.clock.now
        let own = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", photoFile: "mine.jpg"))
        let waiting = try repo.addListing(NewListing(gymId: gym.id, kindId: "kettlebell"))
        let theirs = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", photoFile: "theirs.jpg"))
        let states: [(UUID, UploadState, Bool)] = [(own.id, .uploaded, true), (waiting.id, .queued, true),
                                                   (theirs.id, .uploaded, false)]
        for (id, state, isOwn) in states {
            let row = try #require(try listing(id))
            row.visibilityRaw = GymVisibility.shared.rawValue
            row.uploadStateRaw = state.rawValue
            row.isOwn = isOwn
            row.remoteId = state == .uploaded ? id : nil
            row.remotePhotoPath = "\(UUID().uuidString.lowercased()).jpg"
            row.confirmCount = 3
        }
        let itemId = try #require(try listing(theirs.id)).itemId
        let itemRow = try item(itemId)
        itemRow.catalogPhotoPath = "\(UUID().uuidString.lowercased()).jpg"
        itemRow.catalogPhotoListingId = theirs.id
        f.context.insert(ShareOutboxRecord(kind: .share, targetId: waiting.id, ownerId: UUID(), now: f.clock.now))
        try f.context.save()
        f.store.ownerUserId = UUID()
        f.store.syncedServer = "http://127.0.0.1:55421"
        return OldCatalogue(gym: gym.id, own: own.id, waiting: waiting.id, theirs: theirs.id, item: itemId)
    }

    @Test func theUsersOwnSharedListingsStayOnThePhoneAndTheOldCatalogueIsForgotten() throws {
        defer { f.tearDown() }
        let old = try oldCatalogue()

        #expect(try f.store.moveToServer(new))

        for id in [old.own, old.waiting] {
            let row = try #require(try listing(id))
            #expect(row.visibilityRaw == GymVisibility.device.rawValue)
            #expect(row.uploadStateRaw == UploadState.local.rawValue)
            #expect(row.remoteId == nil && row.remotePhotoPath == nil && row.confirmCount == 0)
        }
        #expect(try listing(old.own)?.photoFile == "mine.jpg", "the picture stays on the phone")
        #expect(try listing(old.theirs)?.visibilityRaw == GymVisibility.shared.rawValue,
                "someone else's listing waits for the next refresh, which drops it with its picture")
        let gym = try gymRecord(old.gym)
        #expect(gym.remoteId != nil && gym.catalogRefreshedAt == nil)
        let borrowed = try item(old.item)
        #expect(borrowed.catalogPhotoPath == nil && borrowed.catalogPhotoListingId == nil)
        #expect(try f.context.fetch(FetchDescriptor<ShareOutboxRecord>()).isEmpty)
    }

    @Test func theNextOpenAsksTheNewServerAndDropsTheOldServersListingsAndPictures() async throws {
        defer { f.tearDown() }
        let old = try oldCatalogue()
        try f.store.moveToServer(new)
        let client = GymCatalogClient(repository: repo, transport: transport, knownKinds: ["cable-stack", "kettlebell"],
                                      now: { [clock = f.clock] in clock.now })

        let refresh = try await client.refresh(gymId: old.gym, force: false)

        #expect(try listing(old.theirs) == nil)
        #expect(refresh.filesToDelete == ["theirs.jpg"])
        #expect(try listing(old.own) != nil)
        #expect(try listing(old.waiting) != nil)
        #expect(try gymRecord(old.gym).remoteId == nil, "the new server has no gym at this place yet")
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd ios/Packages/GymData && swift test --filter SyncStoreServerMoveCatalogueTests`
Expected: FAIL. The own listings stay shared, and the stamp and the outbox stay.

- [ ] **Step 3: Forget the old catalogue in the move**

Replace `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+ServerMove.swift` with:

```swift
import Foundation
import SwiftData

// The server move (docs/specs/2026-11-07-cloudflare-backend-design.md, section 4): when this build talks to another API
// than the one the data last synced with, the local copy goes to the next account that signs in, and every record that
// synced goes up again. Nothing is deleted except Claude's pending proposals, which only the old server could resolve.
extension SyncStore {
    private static let serverKey = "gymrollins.sync.server"

    /// The API this phone's data last synced with (`ApiConfig.origin`); nil until a launch records one.
    public var syncedServer: String? {
        get { defaults.string(forKey: Self.serverKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.serverKey) }
            else { defaults.removeObject(forKey: Self.serverKey) }
        }
    }

    private static let catalogueKey = "gymrollins.catalog.server"

    /// The API the shared catalogue's cache came from; nil until a launch records one. Separate from `syncedServer`.
    public var catalogueServer: String? {
        get { defaults.string(forKey: Self.catalogueKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.catalogueKey) }
            else { defaults.removeObject(forKey: Self.catalogueKey) }
        }
    }

    /// Run at launch next to `moveToServer`, whatever the account did. When the catalogue marker differs from `server`,
    /// the old catalogue is forgotten, the store saved, and then the marker recorded. Returns whether it ran.
    @discardableResult
    public func forgetCatalogueOfOtherServer(_ server: String) throws -> Bool {
        guard catalogueServer != server else { return false }
        do {
            try forgetOldCatalogue()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        catalogueServer = server
        return true
    }

    /// Run at launch, before the session is restored, with the API this build talks to. When another server (or none)
    /// is recorded and the data carries an owner, a pull cursor or a server version, the move runs:
    /// - the owner, the cursors and the recorded refusals are forgotten;
    /// - every record that syncs with the account loses its server version and goes dirty, keeping its edit time;
    /// - synced listings forget the old server's photo names, so pictures on this phone upload again;
    /// - pending proposals go, and resolutions not yet sent count as sent;
    /// - the shared catalogue forgets the old server (`forgetOldCatalogue`).
    /// Then `server` is recorded. The store is saved before anything in `defaults` changes, so a move that fails runs
    /// again at the next launch. Returns whether the move ran.
    @discardableResult
    public func moveToServer(_ server: String) throws -> Bool {
        guard syncedServer != server else { return false }
        let moves = try hasServerState()
        if moves {
            try markEverythingUnsynced()
            for entity in SyncEntity.allCases { clearCursor(for: entity) }
            forgetOwnershipAndFailures()
        }
        syncedServer = server
        return moves
    }

    /// An owner, a pull cursor, or a record holding a server version.
    private func hasServerState() throws -> Bool {
        if ownerUserId != nil || SyncEntity.allCases.contains(where: { cursor(for: $0) != nil }) { return true }
        return try accountRecords().contains { $0.serverUpdatedAt != nil }
    }

    private func markEverythingUnsynced() throws {
        for record in try accountRecords() {
            record.serverUpdatedAt = nil
            record.dirty = true
        }
        let synced = GymVisibility.synced.rawValue
        for listing in try context.fetch(FetchDescriptor<GymListingRecord>(
            predicate: #Predicate { $0.visibilityRaw == synced })) {
            listing.remotePhotoPath = nil
        }
        try forgetOldCatalogue()
        let pending = ProposalStatus.pending.rawValue
        for proposal in try context.fetch(FetchDescriptor<ProposalRecord>()) {
            if proposal.statusRaw == pending {
                context.delete(proposal)
            } else {
                proposal.dirty = false
                proposal.serverUpdatedAt = nil
            }
        }
        try context.save()
    }

    /// The shared catalogue's cache names the old server's rows: its gym ids, listings and pictures, and the outbox's
    /// shares, confirmations, reports and blocks (for the old account). None of them is on the new server.
    /// - The user's own shared listings, and those still waiting to be shared, become "This phone only", with their
    ///   photos: they are the user's equipment, and sharing them again is the user's call.
    /// - Other people's cached listings stay until the gym's next refresh, which the cleared stamp makes its next open.
    ///   The new server doesn't know the old gym id, so that refresh drops them and their pictures, as it does when a
    ///   moderator removed a gym; the maps gym keeps the old id until then, because that is how the refresh finds out.
    /// - A flagged or removed own listing becomes active again; an `unsupported` one stays (it has no loads).
    /// - Items lose the catalogue picture they borrowed, and the outbox is emptied.
    private func forgetOldCatalogue() throws {
        let shared = GymVisibility.shared.rawValue
        let uploaded = UploadState.uploaded.rawValue
        let cached = try context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.visibilityRaw == shared }))
        for listing in cached where listing.isOwn || listing.uploadStateRaw != uploaded {
            listing.visibilityRaw = GymVisibility.device.rawValue
            listing.uploadStateRaw = UploadState.local.rawValue
            listing.uploadError = nil
            listing.duplicatesData = nil
            listing.remoteId = nil
            listing.remotePhotoPath = nil
            if listing.statusRaw != ListingStatus.unsupported.rawValue { // `unsupported` loads are `{}`; stay that way
                listing.statusRaw = ListingStatus.active.rawValue
            }
            listing.confirmCount = 0
            listing.confirmedByMe = false
        }
        for gym in try context.fetch(FetchDescriptor<GymRecord>()) where gym.mapsPlaceId != nil {
            gym.catalogRefreshedAt = nil
        }
        for item in try context.fetch(FetchDescriptor<EquipmentItemRecord>()) where item.catalogPhotoPath != nil {
            item.catalogPhotoPath = nil
            item.catalogPhotoListingId = nil
        }
        for row in try context.fetch(FetchDescriptor<ShareOutboxRecord>()) { context.delete(row) }
    }

    /// Every record that syncs with the account: the aggregate roots, and the gyms and listings synced to it ("This
    /// phone only" rows and the shared catalogue's are left alone).
    private func accountRecords() throws -> [any SyncTracked] {
        let synced = GymVisibility.synced.rawValue
        var records: [any SyncTracked] = []
        records += try every(ProfileRecord.self)
        records += try every(CustomExerciseRecord.self)
        records += try every(ExercisePreferenceRecord.self)
        records += try every(RoutineRecord.self)
        records += try every(WeekdayRecord.self)
        records += try every(MuscleTargetRecord.self)
        records += try every(BodyweightRecord.self)
        records += try every(WorkoutRecord.self)
        records += try context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.visibilityRaw == synced }))
            .map { $0 as any SyncTracked }
        records += try context.fetch(FetchDescriptor<GymListingRecord>(
            predicate: #Predicate { $0.visibilityRaw == synced })).map { $0 as any SyncTracked }
        return records
    }

    private func every<T: PersistentModel & SyncTracked>(_ type: T.Type) throws -> [any SyncTracked] {
        try context.fetch(FetchDescriptor<T>()).map { $0 as any SyncTracked }
    }
}
```

What changed from plan 27's file:
- the doc line about the catalogue;
- `try forgetOldCatalogue()` in `markEverythingUnsynced`, before its single `save`, so a failed move still runs again;
- the new `forgetOldCatalogue()`.

> **Added after review.** The catalogue has its own marker, `gymrollins.catalog.server` (`catalogueServer`), and
> `forgetCatalogueOfOtherServer(_:)` runs `forgetOldCatalogue` whenever it differs from the origin, independent of the
> account move: a phone that recorded the Worker origin under an earlier build, or only browsed signed out, would
> otherwise keep the old gym ids, and the first refresh would delete the user's own listings as `.gone`. The app calls
> it in `SyncCoordinator+Factory.moveIfNeeded`, before `moveToServer`. `unsupported` own listings keep that status.
> Tests: `aCatalogueFromAnotherServerIsForgotten...`, `aSignedOutPhone...`, `forgettingTheCatalogueTwiceIsANoOp`,
> `aFreshInstall...`, `anUnsupportedListingStays...` (`SyncStoreServerMoveCatalogueTests`).

- [ ] **Step 4: Run the tests**

Run: `cd ios/Packages/GymData && swift test`
Expected: `Test run with 365 tests in 50 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/GymData
git commit -m "feat(data): the server move forgets the old server's catalogue and keeps the user's own listings"
```

- [ ] **Step 6: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** spec section 4 "Server move" ("It deletes nothing" of the user's: own listings and photos
   stay), and decision 23.
2. **Quality:** the `code-reviewer` agent.

---

### Task 15: The app on the catalogue API, and exercise photos from the Worker

**Files:**
- Modify: `ios/GymRollins/App/AppEnvironment+GymCatalog.swift`
- Rename: `ios/GymRollins/Features/Media/SupabaseStoragePhotoProvider.swift` → `HostedPhotoProvider.swift`
- Modify: `ios/GymRollins/Features/Media/PhotoHosting.swift`, `ExerciseMediaService.swift`, `PhotoURLPolicy.swift`,
  `EquipmentKindPhotos.swift`, `StoragePhotoManifest.swift`
- Modify: `ios/GymRollinsTests/StoragePhotoHostingTests.swift`, `StoragePhotoIntegrationTests.swift`,
  `EquipmentKindPhotoTests.swift`, `PhotoFallbackAndRefreshTests.swift`
- Modify: `scripts/upload-photos.mjs`, `scripts/test-photo-hosting.sh`, `scripts/test-all.sh`, `docs/media/README.md`

- [ ] **Step 1: The shared catalogue goes through the API**

In `ios/GymRollins/App/AppEnvironment+GymCatalog.swift`:
- Replace the doc comment of `UnavailableGymCatalogTransport` with:

```swift
/// Stands in when the build has no API: reads find nothing and writes need an account. It holds none of the account's
/// photos, so account deletion's photo steps have nothing to detach or remove.
```

- In `makeGymSharing`, replace

```swift
        // The shared catalogue isn't on the API until plan 28, and the Supabase one can't use the API's session.
        let transport: any GymCatalogTransport = UnavailableGymCatalogTransport()
```

with

```swift
        // The catalogue, moderation and shared photos on the API, with the session sync uses (spec section 3).
        let transport: any GymCatalogTransport = sync.auth.map { ApiGymCatalogTransport(api: $0.api) }
            ?? UnavailableGymCatalogTransport()
```

Account deletion's two photo steps (`detachAllPhotos`, then `deleteAllPhotos`, wired in `wireGymSharing`) now reach
`/v1/photos`. Catalogue photos load from `publicPhotoURL`, now `<API_URL>/photos/shared/<name>`, with no session.

- [ ] **Step 2: Exercise photos from `<API_URL>/photos/exercises/`**

Rename the provider and the URL setting, and point the path at the Worker (from `ios/`):

```bash
git mv GymRollins/Features/Media/SupabaseStoragePhotoProvider.swift GymRollins/Features/Media/HostedPhotoProvider.swift
FILES=$(grep -rl -e SupabaseStoragePhotoProvider -e supabaseURL GymRollins GymRollinsTests --include='*.swift')
sed -i '' -e 's/SupabaseStoragePhotoProvider/HostedPhotoProvider/g' -e 's/supabaseURL/apiURL/g' \
  -e 's#storage/v1/object/public/exercise-photos/#photos/exercises/#g' $FILES
```

In `HostedPhotoProvider.swift`, replace the doc comment above the class with:

```swift
/// GymRollins' own photos hosted in the public `exercise-photos` bucket behind the API (uploaded by
/// `scripts/upload-photos.mjs`). Which exercises have photos comes from the bucket's manifest; the photo URLs are
/// `<API_URL>/photos/exercises/own-<id>-<frame>.jpg?v=<rev>`. Without a manifest (first launch offline, fetch failed)
/// it answers nil, so the chain falls through to bundled / free-exercise-db photos.
```

and in it:
- replace `/// \`<SUPABASE_URL>/storage/v1/object/public/exercise-photos/\`` with `/// \`<API_URL>/photos/exercises/\``;
- replace the body of `publicBaseURL(apiURL:)` with
  `apiURL.appending(path: "photos/exercises/", directoryHint: .isDirectory)`.

Replace `ios/GymRollins/Features/Media/PhotoHosting.swift` with:

```swift
import Foundation
import GymSync

/// Where GymRollins' own photos come from, set per build with `PHOTO_HOSTING` (xcconfig -> Info.plist):
/// - `bundle` (default): only the photos bundled in Resources/OwnPhotos.
/// - `storage`: the public `exercise-photos` bucket behind the API (`<API_URL>/photos/exercises/`, manifest-driven),
///   with the bundled photos as fallback. See docs/media/README.md ("Hosting").
enum PhotoHosting: String, Sendable, Equatable {
    case bundle
    case storage

    static let infoKey = "PHOTO_HOSTING"

    /// Missing, empty or unknown values mean `bundle` (the pre-hosting behaviour).
    init(rawSetting: String?) {
        let value = rawSetting?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = PhotoHosting(rawValue: value) ?? .bundle
    }
}

/// The photo hosting settings for this launch.
struct PhotoHostingConfig: Sendable, Equatable {
    let hosting: PhotoHosting
    /// The API's origin (`ApiConfig`); nil when the build has no valid `API_URL`.
    let apiURL: URL?

    /// From Info.plist; in DEBUG, the `PHOTO_HOSTING` and `API_URL` environment variables win (as for sync), so tests
    /// and debug runs can point at a local Worker.
    static func resolve(info: [String: Any], environment: [String: String]) -> PhotoHostingConfig {
        var hostingSetting = info[PhotoHosting.infoKey] as? String
        var apiURL = (try? ApiConfig(info: info))?.baseURL
        #if DEBUG
        if let override = environment[PhotoHosting.infoKey] { hostingSetting = override }
        if let fromEnvironment = try? ApiConfig(environment: environment) { apiURL = fromEnvironment.baseURL }
        #endif
        return PhotoHostingConfig(hosting: PhotoHosting(rawSetting: hostingSetting), apiURL: apiURL)
    }
}
```

In `ios/GymRollinsTests/StoragePhotoHostingTests.swift`, replace the two configuration tests with:

```swift
    @Test func resolvesFromInfoPlist() {
        let info: [String: Any] = ["PHOTO_HOSTING": "storage", "API_URL": "https://gymrollins.example.workers.dev"]
        let config = PhotoHostingConfig.resolve(info: info, environment: [:])
        #expect(config == PhotoHostingConfig(hosting: .storage, apiURL: URL(string: "https://gymrollins.example.workers.dev")))
        #expect(PhotoHostingConfig.resolve(info: [:], environment: [:]) == PhotoHostingConfig(hosting: .bundle, apiURL: nil))
    }

    @Test func debugEnvironmentOverridesInfoPlist() {
        let info: [String: Any] = ["PHOTO_HOSTING": "bundle", "API_URL": "https://gymrollins.example.workers.dev"]
        let env = ["PHOTO_HOSTING": "storage", "API_URL": "http://127.0.0.1:8788"]
        let config = PhotoHostingConfig.resolve(info: info, environment: env)
        #expect(config == PhotoHostingConfig(hosting: .storage, apiURL: URL(string: "http://127.0.0.1:8788")))
    }
```

and delete `private let anon = "anon-key"` if nothing else in the file uses it.

In `ios/GymRollinsTests/StoragePhotoIntegrationTests.swift`:
- replace `End-to-end against the LOCAL Supabase stack` with `End-to-end against a throwaway LOCAL Worker`;
- replace `with \`PHOTO_E2E=1\`, \`SUPABASE_URL\` and \`PHOTO_E2E_ID\`` with
  `with \`PHOTO_E2E=1\`, \`API_URL\` and \`PHOTO_E2E_ID\``;
- replace `environment["SUPABASE_URL"]` with `environment["API_URL"]`.

- [ ] **Step 3: Fill the throwaway Worker's bucket in the photo E2E**

In `scripts/upload-photos.mjs`, replace `workerState: resolve(ROOT, 'server/.wrangler/state'),` with:

```js
  // WORKER_STATE names another local state folder: the photo E2E's throwaway Worker (scripts/test-photo-hosting.sh).
  workerState: process.env.WORKER_STATE ? resolve(process.env.WORKER_STATE) : resolve(ROOT, 'server/.wrangler/state'),
```

Replace `scripts/test-photo-hosting.sh` with:

```bash
#!/usr/bin/env bash
# Exercise photo hosting end to end against a throwaway LOCAL Worker (scripts/test-server.sh: port 8788 and a state
# folder of its own, removed afterwards; never the development data or a deployed Worker):
# 1. uploads two generated test photos into that Worker's R2 with scripts/upload-photos.mjs --target worker,
# 2. checks a second upload is a no-op,
# 3. runs GymRollinsTests/StoragePhotoIntegrationTests (manifest -> provider -> ExercisePhotoStore over local http).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${DEST:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2}"
TEST_ID="9990"
# shellcheck source=scripts/test-server.sh
source "$ROOT/scripts/test-server.sh"

WORK="$(mktemp -d -t photo-hosting-e2e)"
cleanup() {
  local status=$?
  rm -rf "$WORK"
  stop_test_server
  exit "$status"
}
trap cleanup EXIT
start_test_server

mkdir -p "$WORK/photos"
python3 - "$WORK/photos" "$TEST_ID" <<'PY'
import sys
from PIL import Image
out, test_id = sys.argv[1], sys.argv[2]
Image.new("RGB", (30, 20), (230, 120, 40)).save(f"{out}/own-{test_id}-0.jpg", quality=80)
Image.new("RGB", (20, 30), (40, 120, 230)).save(f"{out}/own-{test_id}-1.jpg", quality=80)
PY

upload() {
  WORKER_URL="$TEST_API_URL" WORKER_STATE="$TEST_API_STATE" \
    node "$ROOT/scripts/upload-photos.mjs" --target worker --dir "$WORK/photos"
}
upload
second="$(upload)"
echo "$second"
grep -q "done: 0 uploaded, 2 skipped, 0 failed; manifest unchanged" <<<"$second" \
  || { echo "second upload was not a no-op" >&2; exit 1; }

cd "$ROOT/ios"
xcodegen generate --quiet
LOG="$WORK/xcodebuild.log"
TEST_RUNNER_PHOTO_E2E=1 TEST_RUNNER_API_URL="$TEST_API_URL" TEST_RUNNER_PHOTO_E2E_ID="$TEST_ID" \
  xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins -destination "$DEST" \
  -only-testing:GymRollinsTests/StoragePhotoIntegrationTests \
  -resultBundlePath "$ROOT/ios/build/TestResults-photos-$(date +%s).xcresult" "$@" >"$LOG" 2>&1 \
  || { tail -40 "$LOG" >&2; exit 1; }
# The suite skips itself without PHOTO_E2E=1, which xcodebuild reports as success: require that it really ran.
grep -E "Test uploadedPhotosLoadThroughTheManifestAndProvider\(\) passed" "$LOG" \
  || { tail -40 "$LOG" >&2; echo "the photo E2E test did not run" >&2; exit 1; }
```

In `scripts/test-all.sh`, replace the comment line
`# Storage photo hosting end-to-end against the local Supabase stack (needs Docker): opt in with PHOTO_E2E=1.` with
`# Exercise photo hosting end to end against a throwaway local Worker (no Docker): opt in with PHOTO_E2E=1.`

In `docs/media/README.md`, replace the section "Switch the app to Storage" (from its heading to the line
`the build settings. UI tests (\`-uiTesting\`) never touch Storage.`) with:

```markdown
### Switch the app to the hosted photos

Set `PHOTO_HOSTING = storage` in `ios/Config/Local.xcconfig` (gitignored; default `bundle` in `Base.xcconfig`), then
rebuild. The photos come from `<API_URL>/photos/exercises/` of whatever `API_URL` the build uses:

- **Local Worker (DEBUG only):** the default `API_URL = http://127.0.0.1:8787` works in the simulator once
  `node scripts/upload-photos.mjs --target worker` has filled it. Plain http is allowed only in DEBUG builds and only
  for 127.0.0.1 / localhost, or the configured `API_URL` host when it is a loopback/LAN address — see
  `PhotoURLPolicy`. Release builds load photos over https only; with an http `API_URL` a Release build keeps the
  bundled photos.
- **Deployed Worker:** set its https `API_URL` in `Local.xcconfig` once the owner has deployed it (plan 30's
  checklist).

In DEBUG, the environment variables `PHOTO_HOSTING` and `API_URL` (Xcode scheme) override the build settings. UI tests
(`-uiTesting`) never load hosted photos.
```

- [ ] **Step 4: Build and run the app tests that cover this**

From `ios/`, one at a time, as in plan 27's "How to run things":

```bash
xcodegen generate --quiet
for suite in StoragePhotoHostingTests EquipmentKindPhotoTests PhotoFallbackAndRefreshTests GymWipeEnvironmentTests \
             SyncAccountSafetyTests; do
  xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' -only-testing:GymRollinsTests/$suite \
    -resultBundlePath build/TestResults-one-$(date +%s).xcresult -quiet
done
```

Expected: each run ends `** TEST SUCCEEDED **`. Then run `PHOTO_E2E=1`'s script once:
`DEST='platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' scripts/test-photo-hosting.sh`. It ends with
`Test uploadedPhotosLoadThroughTheManifestAndProvider() passed`.

- [ ] **Step 5: Commit**

```bash
git add ios scripts/upload-photos.mjs scripts/test-photo-hosting.sh scripts/test-all.sh docs/media/README.md
git commit -m "feat(app): the shared catalogue and exercise photos on the API"
```

- [ ] **Step 6: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** spec section 3 (public photos at `/photos/*`), section 7 (the URL cache off for private
   photos; the public ones carry no user id), and decisions 16 and 24.
2. **Quality:** the `code-reviewer` agent and the `swiftui-expert-skill` checklist for the touched app files.

---

### Task 16: The gym suites, and the gym E2E, on the Worker

The five suites parked by plan 27 come back with the same names and checks (decision 25). This task also adds the
test plan 27 asked for: a moved phone's workouts reach the new server with their gym links.

**Files:**
- Create: `ios/Packages/GymSync/Tests/GymSyncIntegrationTests/GymIntegrationSupport.swift`
- Move back from `SupabaseParked/` and rewrite: `GymAccountPhotosIntegrationTests.swift`, `GymCatalogE2ETests.swift`,
  `GymCatalogIntegrationTests.swift`, `GymModerationIntegrationTests.swift`, `GymPrivateIntegrationTests.swift`
- Modify: `ios/Packages/GymSync/Tests/GymSyncIntegrationTests/IntegrationSupport.swift`,
  `ios/Packages/GymSync/Package.swift` (comment only)
- Modify: `scripts/test-sync-integration.sh`, `scripts/test-gym-e2e.sh`, `scripts/test-all.sh`

- [ ] **Step 1: Move the five suites back**

```bash
cd ios/Packages/GymSync/Tests/GymSyncIntegrationTests
git mv SupabaseParked/GymAccountPhotosIntegrationTests.swift SupabaseParked/GymCatalogE2ETests.swift \
  SupabaseParked/GymCatalogIntegrationTests.swift SupabaseParked/GymModerationIntegrationTests.swift \
  SupabaseParked/GymPrivateIntegrationTests.swift .
```

In `ios/Packages/GymSync/Package.swift`, the comment above the `GymSyncIntegrationTests` target now reads:

```swift
        // The Supabase-only suites left (proposals, Claude's grants) sign in with the Supabase client the app no
        // longer has. They stay as the reference plan 29 ports to the API, unbuilt meanwhile.
```

- [ ] **Step 2: The shared support, and account deletion with its photo steps**

`ios/Packages/GymSync/Tests/GymSyncIntegrationTests/GymIntegrationSupport.swift`:

```swift
import Foundation
import GymData
import Testing
@testable import GymSync

/// What the gym suites share on the Worker.
extension Account {
    /// The shared catalogue, moderation and shared photos, as this account's phone reaches them.
    var catalog: ApiGymCatalogTransport { ApiGymCatalogTransport(api: auth.api) }
}

enum GymIntegration {
    /// A JPEG as far as the server checks one (its first bytes, and the declared type), at a photo-like size.
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 596)

    /// A phone with no account: the catalogue answers it `.signedOut`, reads included (spec section 3).
    static func signedOutCatalog() throws -> ApiGymCatalogTransport {
        ApiGymCatalogTransport(api: try IntegrationEnv.config().makeClient(sessions: InMemorySessionStore()))
    }

    static func signedOutTransport() throws -> ApiSyncTransport {
        ApiSyncTransport(api: try IntegrationEnv.config().makeClient(sessions: InMemorySessionStore()))
    }

    /// Whether `/photos/shared/<name>` serves the photo to anyone, past every cache.
    static func isServed(_ name: String) async throws -> Bool {
        let url = try #require(try signedOutCatalog().publicPhotoURL(path: name))
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
```

In `IntegrationSupport.swift`, replace

```swift
    /// The Worker holds no photos before plan 28, so there are no photo steps.
    func deleteAccount() async throws {
        let id = userId
        try await auth.deleteAccount()
        IntegrationEnv.recordDeletedUser(id)
    }
```

with

```swift
    /// Detaches and removes the account's photos first, as the app does, then deletes the account.
    func deleteAccount() async throws {
        let id = userId
        let catalog = ApiGymCatalogTransport(api: auth.api)
        try await auth.deleteAccount(photos: AccountPhotoSteps(detach: { try await catalog.detachAllPhotos() },
                                                               remove: { try await catalog.deleteAllPhotos() }))
        IntegrationEnv.recordDeletedUser(id)
    }
```

- [ ] **Step 3: Rewrite the five suites for the Worker**

Each file is replaced in full.

`GymAccountPhotosIntegrationTests.swift`:

```swift
import Foundation
import GymData
import Testing
@testable import GymSync

/// Account deletion and the photos the account owns, against the local Worker: the app removes them through
/// `/v1/photos` first, and the server refuses to delete the account while any remain.
@MainActor
@Suite(.enabled(if: apiConfigured, "Set API_URL (scripts/test-sync-integration.sh) to run against a local Worker"))
struct GymAccountPhotosIntegrationTests {
    private func catalog(_ account: Account) -> ApiGymCatalogTransport { account.catalog }

    private func photoName() -> String { "\(UUID().uuidString.lowercased()).jpg" }

    /// Uploads to a bucket as the phone does: shared photos through the share queue's transport, private ones
    /// through sync's.
    private func upload(_ account: Account, bucket: String, name: String) async throws {
        if bucket == "gym-photos" {
            _ = try await account.catalog.uploadSharedPhoto(GymIntegration.jpeg, name: name)
        } else {
            _ = try await account.transport.uploadPrivatePhoto(GymIntegration.jpeg, name: name)
        }
    }

    private func owned(_ account: Account) async throws -> [OwnedPhoto] {
        let body = try await account.auth.api.data("GET", "/v1/photos/mine").body
        return try OwnedPhotos.list(from: GymCatalogRows.array(in: body, key: "rows"))
    }

    @Test func deletingAnAccountRemovesItsPhotosAndKeepsTheSharedListing() async throws {
        let user = try await Account.signUp()
        let gymId = try await catalog(user).findOrCreateGym(
            mapsPlaceId: "it-\(UUID().uuidString.lowercased())", name: "Iron Works", address: nil, latitude: 52.5,
            longitude: 13.4)
        let shared = photoName(), orphan = photoName(), privateName = photoName()
        try await upload(user, bucket: "gym-photos", name: shared)
        try await upload(user, bucket: "gym-photos", name: orphan)
        try await upload(user, bucket: "gym-photos-private", name: privateName)
        let listingId = UUID()
        _ = try await catalog(user).share(ShareRequest(
            listingId: listingId, gymId: gymId, kindId: "cable-station", brand: nil, model: nil,
            loads: .stack(maxKg: 90, stepKg: 5), quantity: 1, notes: "mine", photoPath: shared, forceNew: false))
        #expect(try await owned(user).count == 3, "the orphan and the private photo are listed too")

        try await user.deleteAccount()

        // Catalogue reads need a session now, so another account reads what stayed.
        let reader = try await Account.signUp()
        let listings = try await reader.catalog.publicListings(gymId: gymId).listings
        let listing = try #require(listings.first { $0.id == listingId })
        #expect(listing.photoPath == nil)
        #expect(listing.notes == nil)
        #expect(try await !GymIntegration.isServed(shared))
        #expect(try await !GymIntegration.isServed(orphan))
        try await reader.deleteAccount()
    }

    @Test func theServerRefusesToDeleteWhileAPhotoRemains() async throws {
        let user = try await Account.signUp()
        try await upload(user, bucket: "gym-photos-private", name: photoName())
        let refused = await #expect(throws: AuthFailure.self) { try await user.auth.deleteAccount() }
        #expect(refused?.message.contains("still being removed") == true)
        #expect(user.auth.state.userId == user.userId, "the account stays signed in")
        #expect(try await owned(user).count == 1)

        try await catalog(user).deleteAllPhotos()
        try await catalog(user).deleteAllPhotos() // nothing left, and that is fine
        try await user.deleteAccount()
    }

    @Test func removingAPhotoAlreadyGoneIsNotAFailure() async throws {
        let user = try await Account.signUp()
        let name = photoName()
        try await upload(user, bucket: "gym-photos", name: name)
        try await catalog(user).deleteSharedPhoto(path: name)
        try await catalog(user).deleteAllPhotos()
        try await user.deleteAccount()
    }
}
```

`GymModerationIntegrationTests.swift`:

```swift
import Foundation
import GymData
import Testing
@testable import GymSync

/// The admin list against the local Worker. `scripts/test-sync-integration.sh` makes any account named
/// `sync-admin-*@test.local` an admin when it signs up.
@MainActor
@Suite(.enabled(if: apiConfigured, "Set API_URL (scripts/test-sync-integration.sh) to run against a local Worker"))
struct GymModerationIntegrationTests {
    /// This test's own brand: parallel tests that share one would delete each other's item with their accounts.
    private let brand = "Hammer \(UUID().uuidString.prefix(8))"

    private func catalog(_ account: Account) -> ApiGymCatalogTransport { account.catalog }

    private func signUpAdmin() async throws -> Account {
        let account = try Account.fresh(email: "sync-admin-\(UUID().uuidString.lowercased())@test.local")
        try await account.auth.signUp(email: account.email, password: IntegrationEnv.password)
        return account
    }

    private func isServed(_ transport: ApiGymCatalogTransport, _ name: String) async throws -> Bool {
        try await GymIntegration.isServed(name)
    }

    @Test func anAdminRemovesAnotherUsersFlaggedListingAndItsPhotoGoesFromStorage() async throws {
        let author = try await Account.signUp()
        let admin = try await signUpAdmin()
        let plain = try await Account.signUp()
        var reporters: [Account] = []
        for _ in 0..<3 { reporters.append(try await Account.signUp()) }

        let gymId = try await catalog(author).findOrCreateGym(mapsPlaceId: "it-\(UUID().uuidString.lowercased())",
                                                              name: "Iron Works", address: nil, latitude: 52.5,
                                                              longitude: 13.4)
        let name = "\(UUID().uuidString.lowercased()).jpg"
        _ = try await catalog(author).uploadSharedPhoto(GymIntegration.jpeg, name: name)
        let listingId = UUID()
        let request = ShareRequest(listingId: listingId, gymId: gymId, kindId: "cable-station", brand: brand,
                                   model: nil, loads: .stack(maxKg: 90, stepKg: 5), quantity: 1, notes: nil,
                                   photoPath: name, forceNew: false)
        _ = try await catalog(author).share(request)
        for reporter in reporters {
            try await catalog(reporter).report(targetType: .listing, targetId: listingId, reason: .personInPhoto,
                                               note: nil)
        }

        #expect(try await catalog(admin).isAdmin())
        #expect(try await !catalog(plain).isAdmin())
        await #expect(throws: GymCatalogError.notAllowed) { _ = try await catalog(plain).moderationQueue() }
        await #expect(throws: GymCatalogError.notAllowed) {
            _ = try await catalog(plain).moderate(targetType: .listing, targetId: listingId, action: .remove)
        }

        let queued = try #require(try await catalog(admin).moderationQueue().first { $0.targetId == listingId })
        #expect(queued.targetType == .listing)
        #expect(queued.title == brand)
        #expect(queued.status == .flagged)
        #expect(queued.reportCount == 3)
        #expect(queued.reasons == [.init(reason: "person-in-photo", count: 3)])
        #expect(queued.photoPath == name)
        #expect(try await isServed(catalog(admin), name))

        let photo = try await catalog(admin).moderate(targetType: .listing, targetId: listingId, action: .remove)
        #expect(photo == name)
        try await catalog(admin).deleteSharedPhoto(path: name)
        #expect(try await !isServed(catalog(admin), name), "an admin's delete reaches a removed listing's photo")
        // The name stays on a removed listing until the app confirms the object is gone (moderation_photo_deleted), so
        // a failed delete can be retried: the queue still shows it, as removed and still naming the photo.
        let waiting = try #require(try await catalog(admin).moderationQueue().first { $0.targetId == listingId })
        #expect(waiting.status == .removed && waiting.photoPath == name)
        #expect(try await catalog(admin).moderate(targetType: .listing, targetId: listingId, action: .remove) == name,
                "removing again hands the same path out")
        try await catalog(admin).moderationPhotoDeleted(path: name)
        #expect(try await !catalog(admin).moderationQueue().contains { $0.targetId == listingId },
                "once the server hears the object is gone, the listing leaves the queue")

        for account in [author, admin, plain] + reporters { try await account.deleteAccount() }
    }
}
```

`GymCatalogIntegrationTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// `ApiGymCatalogTransport` against the local Worker: the catalogue, moderation and photo routes the app relies on.
@MainActor
@Suite(.enabled(if: apiConfigured, "Set API_URL (scripts/test-sync-integration.sh) to run against a local Worker"))
struct GymCatalogIntegrationTests {
    private func catalog(_ account: Account) -> ApiGymCatalogTransport { account.catalog }

    /// A phone with no account: the catalogue answers it `.signedOut`, reads included.
    private func anonCatalog() throws -> ApiGymCatalogTransport { try GymIntegration.signedOutCatalog() }

    private func freshPlace() -> String { "it-\(UUID().uuidString.lowercased())" }

    /// A JPEG: the server checks the bytes as well as the declared type.
    private func photo() -> Data { GymIntegration.jpeg }

    private func photoName() -> String { "\(UUID().uuidString.lowercased()).jpg" }

    /// Every test has a brand of its own. Suites run in parallel and share the server, and an item with a brand only
    /// the test's account used is deleted with that account: two tests sharing "Hammer" could delete each other's
    /// item between `share_listing` finding it and inserting the listing.
    private let ownBrand = "Hammer \(UUID().uuidString.prefix(8))"

    private func request(_ id: UUID = UUID(), gym: UUID, kind: String = "cable-station", brand: String? = nil,
                         brandless: Bool = false, photo: String? = nil, forceNew: Bool = false) -> ShareRequest {
        ShareRequest(listingId: id, gymId: gym, kindId: kind, brand: brandless ? nil : (brand ?? ownBrand),
                     model: nil,
                     loads: .stack(maxKg: 90, stepKg: 5), quantity: 2, notes: "by the door", photoPath: photo,
                     forceNew: forceNew)
    }

    private func gym(_ transport: ApiGymCatalogTransport, place: String) async throws -> UUID {
        try await transport.findOrCreateGym(mapsPlaceId: place, name: "Iron Works", address: "1 Main St",
                                            latitude: 52.5, longitude: 13.4)
    }

    @Test func aSharedListingWithAPhotoReadsBackThroughAnotherAccountButNotSignedOut() async throws {
        let user = try await Account.signUp()
        let transport = catalog(user)
        let place = freshPlace()
        let gymId = try await gym(transport, place: place)
        #expect(try await gym(transport, place: place) == gymId)

        let name = photoName()
        #expect(try await transport.uploadSharedPhoto(photo(), name: name) == name)
        let listingId = UUID()
        #expect(try await transport.share(request(listingId, gym: gymId, photo: name)) == .created(listingId))
        #expect(try await transport.share(request(listingId, gym: gymId, photo: name)) == .created(listingId))

        await #expect(throws: GymCatalogError.signedOut) { _ = try await anonCatalog().publicGym(mapsPlaceId: place) }
        let reader = try await Account.signUp()
        let anon = catalog(reader)
        let found = try #require(try await anon.publicGym(mapsPlaceId: place))
        #expect(found.id == gymId)
        #expect(found.name == "Iron Works")
        let listings = try await anon.publicListings(gymId: gymId).listings
        let listing = try #require(listings.first)
        #expect(listing.id == listingId)
        #expect(listing.kindId == "cable-station")
        #expect(listing.brand == ownBrand)
        #expect(listing.loads == .stack(maxKg: 90, stepKg: 5))
        #expect(listing.quantity == 2)
        #expect(listing.photoPath == name)
        #expect(!listing.isMine)
        #expect(!listing.confirmedByMe)

        let mine = try #require(try await transport.publicListings(gymId: gymId).listings.first)
        #expect(mine.isMine)

        let items = try await anon.publicItems(kindId: "cable-station")
        let item = try #require(items.first { $0.id == listing.itemId })
        #expect(item.photoPath == name)
        #expect(item.photoListingId == listingId)

        let url = try #require(anon.publicPhotoURL(path: name))
        #expect(!url.absoluteString.contains(user.userId.uuidString.lowercased()))
        let (_, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        try await user.deleteAccount()
        try await reader.deleteAccount()
    }

    @Test func aSecondShareOfTheKindReturnsDuplicatesUnlessForced() async throws {
        let first = try await Account.signUp()
        let second = try await Account.signUp()
        let gymId = try await gym(catalog(first), place: freshPlace())
        let original = UUID()
        _ = try await catalog(first).share(request(original, gym: gymId))

        let result = try await catalog(second).share(request(gym: gymId))
        guard case let .duplicates(found) = result else { Issue.record("expected duplicates, got \(result)"); return }
        #expect(found.map(\.id) == [original])
        #expect(found.first?.kindId == "cable-station")
        #expect(found.first?.loads == .stack(maxKg: 90, stepKg: 5))

        let forced = UUID()
        #expect(try await catalog(second).share(request(forced, gym: gymId, forceNew: true)) == .created(forced))
        let listings = try await catalog(second).publicListings(gymId: gymId).listings
        #expect(Set(listings.map(\.id)) == [original, forced])
        #expect(try await catalog(second).confirm(listingId: original) == 1)
        #expect(try await catalog(second).confirm(listingId: original) == 1)
        try await first.deleteAccount()
        try await second.deleteAccount()
    }

    @Test func uploadingTheSamePhotoTwiceSucceeds() async throws {
        let user = try await Account.signUp()
        let transport = catalog(user)
        let name = photoName()
        #expect(try await transport.uploadSharedPhoto(photo(), name: name) == name)
        #expect(try await transport.uploadSharedPhoto(photo(), name: name) == name)
        try await user.deleteAccount()
    }

    @Test func aNameAListingUsesCannotBeUploadedAgain() async throws {
        let user = try await Account.signUp()
        let transport = catalog(user)
        let gymId = try await gym(transport, place: freshPlace())
        let name = photoName()
        _ = try await transport.uploadSharedPhoto(photo(), name: name)
        let listingId = UUID()
        _ = try await transport.share(request(listingId, gym: gymId, photo: name))

        try await transport.deleteSharedPhoto(path: name)
        // The name stays a listing's after its object went (photo_name_in_use): every photo refusal is one answer.
        await #expect(throws: GymCatalogError.photoRefused) {
            _ = try await transport.uploadSharedPhoto(photo(), name: name)
        }
        try await user.deleteAccount()
    }

    private func isServed(_ transport: ApiGymCatalogTransport, _ name: String) async throws -> Bool {
        try await GymIntegration.isServed(name)
    }

    @Test func onlyTheOwnerCanDeleteAnUploadedPhoto() async throws {
        let owner = try await Account.signUp()
        let other = try await Account.signUp()
        let name = photoName()
        _ = try await catalog(owner).uploadSharedPhoto(photo(), name: name)
        #expect(try await isServed(catalog(owner), name))

        try await catalog(other).deleteSharedPhoto(path: name)
        #expect(try await isServed(catalog(owner), name), "another user's delete removes nothing")
        try await catalog(owner).deleteSharedPhoto(path: name)
        #expect(try await !isServed(catalog(owner), name))
        try await catalog(owner).deleteSharedPhoto(path: name) // already gone: fine
        try await owner.deleteAccount()
        try await other.deleteAccount()
    }

    @Test func anotherUsersUploadedPhotoCannotBeShared() async throws {
        let owner = try await Account.signUp()
        let thief = try await Account.signUp()
        let gymId = try await gym(catalog(owner), place: freshPlace())
        let name = photoName()
        _ = try await catalog(owner).uploadSharedPhoto(photo(), name: name)

        await #expect(throws: GymCatalogError.photoMissing) {
            _ = try await catalog(thief).share(request(gym: gymId, photo: name))
        }
        try await owner.deleteAccount()
        try await thief.deleteAccount()
    }

    @Test func anAnonymousWriteIsSignedOutAndAnUnknownGymIsNotShareable() async throws {
        let anon = try anonCatalog()
        await #expect(throws: GymCatalogError.signedOut) {
            _ = try await anon.confirm(listingId: UUID())
        }
        await #expect(throws: GymCatalogError.signedOut) {
            _ = try await anon.uploadSharedPhoto(photo(), name: photoName())
        }
        let user = try await Account.signUp()
        await #expect(throws: GymCatalogError.gymNotShareable) {
            _ = try await catalog(user).share(request(gym: UUID()))
        }
        try await user.deleteAccount()
    }

    @Test func aGymNobodyHasSharedYetIsAbsent() async throws {
        let user = try await Account.signUp()
        #expect(try await catalog(user).publicGym(mapsPlaceId: freshPlace()) == nil)
        try await user.deleteAccount()
    }

    // MARK: Reports and blocks

    @Test func aReportBlockAndUnblockGoThroughTheServer() async throws {
        let author = try await Account.signUp()
        let reader = try await Account.signUp()
        let gymId = try await gym(catalog(author), place: freshPlace())
        let kept = UUID(), reported = UUID()
        _ = try await catalog(author).share(request(kept, gym: gymId, kind: "cable-station", brandless: true))
        _ = try await catalog(author).share(request(reported, gym: gymId, kind: "leg-press", brandless: true))

        // Nothing to say about the author's own listing: the server answers `own`, which is not an error.
        try await catalog(author).report(targetType: .listing, targetId: reported, reason: .spam, note: nil)
        try await catalog(reader).report(targetType: .listing, targetId: reported, reason: .wrongInfo, note: "a note")
        try await catalog(reader).report(targetType: .listing, targetId: reported, reason: .wrongInfo, note: nil)
        try await catalog(reader).report(targetType: .gym, targetId: gymId, reason: .notHereAnymore, note: nil)

        await #expect(throws: GymCatalogError.unknownTarget) {
            try await catalog(reader).report(targetType: .listing, targetId: UUID(), reason: .spam, note: nil)
        }
        await #expect(throws: GymCatalogError.noteRefused) {
            try await catalog(reader).report(targetType: .listing, targetId: kept, reason: .other, note: "bad\u{7}note")
        }
        await #expect(throws: GymCatalogError.signedOut) {
            try await anonCatalog().report(targetType: .listing, targetId: kept, reason: .spam, note: nil)
        }

        try await catalog(reader).blockAuthor(targetType: .listing, targetId: kept)
        #expect(try await catalog(reader).publicListings(gymId: gymId).listings.isEmpty)
        #expect(try await catalog(author).publicListings(gymId: gymId).listings.count == 2)
        #expect(try await catalog(reader).unblockAll() == 1)
        #expect(try await catalog(reader).publicListings(gymId: gymId).listings.count == 2)
        #expect(try await catalog(reader).unblockAll() == 0)
        try await author.deleteAccount()
        try await reader.deleteAccount()
    }
}
```

`GymPrivateIntegrationTests.swift`. Besides the new last test, the changes are:
- `anonTransport()` is a signed-out `ApiSyncTransport`;
- `user.catalog`;
- the JPEG.

```swift
import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymSync

private final class MemoryPhotoFiles: GymPhotoFiles, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]
    init(_ files: [String: Data] = [:]) { self.files = files }
    var stored: [String: Data] { lock.withLock { files } }
    func data(file: String) -> Data? { lock.withLock { files[file] } }
    func save(_ jpeg: Data, file: String) throws { lock.withLock { files[file] = jpeg } }
    func delete(file: String) throws { lock.withLock { files[file] = nil } }
}

/// Private gyms, listings and photos against the local stack: a second device of the same user gets them; another
/// user and a signed-out client get nothing.
@MainActor
@Suite(.enabled(if: apiConfigured, "Set API_URL (scripts/test-sync-integration.sh) to run against a local Worker"))
struct GymPrivateIntegrationTests {
    @MainActor private struct Phone {
        let container: ModelContainer
        let store: SyncStore
        let engine: SyncEngine
        let photos: MemoryPhotoFiles
        let repo: GymRepository

        init(_ account: Account, clock: DeviceClock, photos: MemoryPhotoFiles = MemoryPhotoFiles()) throws {
            container = try GymStore.container(inMemory: true)
            let defaults = UserDefaults(suiteName: "gym-it-\(UUID())")!
            store = SyncStore(context: container.mainContext, defaults: defaults, now: { clock.now })
            engine = SyncEngine(store: store, transport: account.transport, photos: photos, now: { clock.now })
            self.photos = photos
            repo = GymRepository(context: container.mainContext, now: { clock.now })
        }
    }

    private func anonTransport() throws -> ApiSyncTransport { try GymIntegration.signedOutTransport() }

    @Test func aPrivateGymListingAndPhotoReachAnotherDeviceAndNoOneElse() async throws {
        let owner = try await Account.signUp()
        let stranger = try await Account.signUp()
        let clock = DeviceClock("2026-10-30T12:00:00.000000Z")
        let jpeg = GymIntegration.jpeg
        let first = try Phone(owner, clock: clock, photos: MemoryPhotoFiles(["mine.jpg": jpeg]))

        let gym = try first.repo.addPrivateGym(name: "Garage", address: "1 Home St")
        let listing = try first.repo.addListing(NewListing(gymId: gym.id, kindId: "cable-station", brand: "Hammer",
                                                           loads: .stack(maxKg: 90, stepKg: 5), notes: "garage",
                                                           photoFile: "mine.jpg"))
        try first.repo.makeSynced(listing: listing.id)
        await first.engine.sync()
        #expect(first.engine.status == .idle)
        #expect(try first.store.dirtyGyms().isEmpty && first.store.dirtyGymListings().isEmpty,
                "\(first.store.syncFailures().map(\.message)) \(first.engine.status)")
        let path = try #require(try first.container.mainContext.fetch(FetchDescriptor<GymListingRecord>()).first?.remotePhotoPath)

        let other = try Phone(stranger, clock: clock)
        await other.engine.sync()
        #expect(try other.repo.gyms().isEmpty)

        let second = try Phone(try await owner.onAnotherDevice(), clock: clock)
        await second.engine.sync()
        #expect(second.engine.status == .idle)

        // The owner has now downloaded the picture; no client may be served it from a cache afterwards.
        let anon = try anonTransport()
        // Refused outright or empty: either way a signed-out client reads nothing.
        #expect((try? await anon.pullGyms(since: nil))?.isEmpty ?? true)
        #expect((try? await anon.pullGymListings(since: nil))?.isEmpty ?? true)
        await #expect(throws: (any Error).self) { _ = try await anon.downloadPrivatePhoto(path: path) }
        await #expect(throws: (any Error).self) { _ = try await stranger.transport.downloadPrivatePhoto(path: path) }

        let copy = try #require(try second.repo.listings(gymId: gym.id).first)
        #expect(copy.id == listing.id && copy.item.brand == "Hammer" && copy.notes == "garage")
        #expect(copy.loads == .stack(maxKg: 90, stepKg: 5))
        let file = try #require(copy.photoFile)
        #expect(second.photos.stored[file] == jpeg)

        clock.advance(60)
        _ = try first.repo.removeListing(listing.id)
        await first.engine.sync()
        #expect(try first.container.mainContext.fetchCount(FetchDescriptor<GymListingRecord>()) == 0)
        clock.advance(60)
        await second.engine.sync()
        #expect(try second.repo.listings(gymId: gym.id).isEmpty)
        await #expect(throws: (any Error).self) { _ = try await owner.transport.downloadPrivatePhoto(path: path) }

        try await owner.deleteAccount()
        try await stranger.deleteAccount()
    }

    @Test func aWorkoutKeepsItsSyncedGymAndListingAcrossDevicesButNeverALocalOne() async throws {
        let owner = try await Account.signUp()
        let clock = DeviceClock("2026-10-30T12:00:00.000000Z")
        let first = try Phone(owner, clock: clock)
        let workouts = WorkoutRepository(context: first.container.mainContext, now: { clock.now })

        let gym = try first.repo.addPrivateGym(name: "Garage", address: nil)
        let listing = try first.repo.addListing(NewListing(gymId: gym.id, kindId: "cable-station",
                                                           loads: .stack(maxKg: 90, stepKg: 5)))
        try first.repo.makeSynced(listing: listing.id)
        let local = try first.repo.addPrivateGym(name: "Phone only", address: nil)
        let localListing = try first.repo.addListing(NewListing(gymId: local.id, kindId: "cable-station"))
        await first.engine.sync()

        func workout(gym: UUID, listing: UUID) -> Workout {
            Workout(startedAt: clock.now, endedAt: clock.now.addingTimeInterval(600), name: "Pull", entries: [
                WorkoutEntry(exerciseId: "bench", sets: [WorkoutSet(weightKg: 50, reps: 8, done: true)],
                             gymListingId: listing)], gymId: gym)
        }
        let linked = workout(gym: gym.id, listing: listing.id)
        let phoneOnly = workout(gym: local.id, listing: localListing.id)
        try workouts.save(linked)
        try workouts.save(phoneOnly)
        await first.engine.sync()
        #expect(first.engine.status == .idle, "\(first.store.syncFailures().map(\.message))")
        #expect(try workouts.workout(phoneOnly.id)?.gymId == local.id, "a pull never clears a local link")

        let second = try Phone(try await owner.onAnotherDevice(), clock: clock)
        await second.engine.sync()
        let other = WorkoutRepository(context: second.container.mainContext, now: { clock.now })
        #expect(try other.workout(linked.id)?.gymId == gym.id)
        #expect(try other.workout(linked.id)?.entries.first?.gymListingId == listing.id)
        #expect(try other.workout(phoneOnly.id)?.gymId == nil)

        try await owner.deleteAccount()
    }
    // MARK: Two accounts on one phone

    @Test func theNextAccountOnThePhoneGetsItsOwnGymIdsAndBothAccountsKeepTheirRows() async throws {
        let first = try await Account.signUp()
        let second = try await Account.signUp()
        let clock = DeviceClock("2026-10-30T12:00:00.000000Z")
        let phone = try Phone(first, clock: clock)
        phone.store.ownerUserId = first.userId
        let gym = try phone.repo.addPrivateGym(name: "Garage", address: nil)
        let listing = try phone.repo.addListing(NewListing(gymId: gym.id, kindId: "cable-station"))
        try phone.repo.makeSynced(listing: listing.id)
        await phone.engine.sync()
        #expect(try phone.store.dirtyGyms().isEmpty)
        // Edited while offline, so the listing survives the sign-out as an unpushed change.
        clock.advance(60)
        _ = try phone.repo.updateListing(listing.id, loads: .none, quantity: 2, notes: "edited offline")
        _ = try phone.store.resetAccountData()

        // The second account signs in on the same phone, syncs the gym and a workout.
        phone.store.ownerUserId = second.userId
        let moves = try phone.store.settleDemotedRows(for: second.userId)
        let newGym = try #require(moves[gym.id])
        let workouts = WorkoutRepository(context: phone.container.mainContext, now: { clock.now })
        try workouts.save(finishedWorkout(name: "Push", at: clock.now))
        try phone.repo.makeSynced(gym: newGym)
        let engine = SyncEngine(store: phone.store, transport: second.transport, photos: phone.photos,
                                now: { clock.now })
        await engine.sync()
        #expect(engine.status == .idle, "\(phone.store.syncFailures().map(\.message))")
        #expect(phone.store.syncFailures().isEmpty)

        #expect(try await second.transport.pullGyms(since: nil).map(\.id) == [newGym])
        #expect(try await second.transport.pullWorkouts(since: nil).count == 1)
        let untouched = try await first.transport.pullGyms(since: nil)
        #expect(untouched.map(\.id) == [gym.id] && untouched.first?.name == "Garage")
        let theirs = try await first.transport.pullGymListings(since: nil)
        #expect(theirs.map(\.id) == [listing.id] && theirs.first?.notes == nil)

        try await first.deleteAccount()
        try await second.deleteAccount()
    }

    @Test func aGymAnotherAccountHoldsIsRefusedForThatRowAndTheRoundGoesOn() async throws {
        let first = try await Account.signUp()
        let second = try await Account.signUp()
        let clock = DeviceClock("2026-10-30T12:00:00.000000Z")
        let phoneA = try Phone(first, clock: clock)
        let gym = try phoneA.repo.addPrivateGym(name: "Garage", address: nil)
        try phoneA.repo.makeSynced(gym: gym.id)
        await phoneA.engine.sync()

        // A phone whose row carries the first account's id (what an old demoted row used to look like).
        let phoneB = try Phone(second, clock: clock)
        let clash = GymRecord(id: gym.id, name: "Mine now", address: nil, now: clock.now)
        clash.visibilityRaw = GymVisibility.synced.rawValue
        clash.dirty = true
        phoneB.container.mainContext.insert(clash)
        try phoneB.container.mainContext.save()
        let workouts = WorkoutRepository(context: phoneB.container.mainContext, now: { clock.now })
        try workouts.save(finishedWorkout(name: "Push", at: clock.now))
        await phoneB.engine.sync()

        #expect(try await second.transport.pullWorkouts(since: nil).count == 1, "the workout is not held back")
        #expect(phoneB.store.syncFailures().map(\.entity) == [.gyms])
        let untouched = try await first.transport.pullGyms(since: nil)
        #expect(untouched.first?.name == "Garage")

        try await first.deleteAccount()
        try await second.deleteAccount()
    }

    /// Account deletion that fails after the photos went: no row names a deleted object, the phone uploads its pictures
    /// again at the next sync, and a retry deletes the account.
    @Test func aDeletionRefusedAfterThePhotosWentLeavesNoRowNamingThemAndTheNextSyncUploadsAgain() async throws {
        let user = try await Account.signUp()
        let clock = DeviceClock("2026-10-30T12:00:00.000000Z")
        let jpeg = GymIntegration.jpeg
        let phone = try Phone(user, clock: clock, photos: MemoryPhotoFiles(["mine.jpg": jpeg]))
        let catalog = user.catalog

        let gym = try phone.repo.addPrivateGym(name: "Garage", address: nil)
        let listing = try phone.repo.addListing(NewListing(gymId: gym.id, kindId: "cable-station",
                                                           loads: .stack(maxKg: 90, stepKg: 5), photoFile: "mine.jpg"))
        try phone.repo.makeSynced(listing: listing.id)
        await phone.engine.sync()
        let record = try #require(try phone.container.mainContext.fetch(FetchDescriptor<GymListingRecord>()).first)
        let oldPath = try #require(record.remotePhotoPath)

        let place = "it-\(UUID().uuidString.lowercased())"
        let sharedGym = try await catalog.findOrCreateGym(mapsPlaceId: place, name: "Iron Works", address: nil,
                                                          latitude: 52.5, longitude: 13.4)
        let sharedName = "\(UUID().uuidString.lowercased()).jpg"
        _ = try await catalog.uploadSharedPhoto(jpeg, name: sharedName)
        let sharedId = UUID()
        _ = try await catalog.share(ShareRequest(
            listingId: sharedId, gymId: sharedGym, kindId: "leg-press", brand: nil, model: nil,
            loads: .stack(maxKg: 90, stepKg: 5), quantity: 1, notes: nil, photoPath: sharedName, forceNew: false))

        // The server stamps the detach with its real clock, and the phone's edit has to be newer than that, as a real
        // phone's is a moment later; the fixed clock the other tests use is a day behind.
        clock.now = Date().addingTimeInterval(60)
        struct Refused: Error {}
        nonisolated(unsafe) let store = phone.store
        let steps = AccountPhotoSteps(
            detach: { try await catalog.detachAllPhotos(); try await MainActor.run { try store.forgetRemotePhotos() } },
            remove: { try await catalog.deleteAllPhotos() })
        // The server step fails after the photos are gone, as a lost connection or a refusal would.
        await #expect(throws: AuthFailure.self) {
            try await user.auth.deleteAccount(photos: steps) { throw Refused() }
        }

        let rows = try await user.transport.pullGymListings(since: nil)
        #expect(rows.count == 1 && rows.first.map { $0.photoPath } == .some(nil), "the server's row holds no path")
        let shared = try #require(try await catalog.publicListings(gymId: sharedGym).listings.first { $0.id == sharedId })
        #expect(shared.photoPath == nil, "the shared listing stays, without its photo")
        #expect(record.remotePhotoPath == nil && record.photoFile == "mine.jpg" && record.dirty)

        clock.advance(60)
        await phone.engine.sync()
        let newPath = try #require(record.remotePhotoPath)
        #expect(newPath != oldPath, "the picture went up again under a new name")
        #expect(try await user.transport.pullGymListings(since: nil).first?.photoPath == newPath)
        #expect(try await user.transport.downloadPrivatePhoto(path: newPath) == jpeg)

        try await user.deleteAccount() // the retry
    }

    // MARK: After a server move

    /// Plan 27 left this to plan 28: a phone moved from another server sends its gyms and listings in the same round
    /// as the workouts that link them, gyms first, so the links reach the new server.
    @Test func aPhoneMovedFromAnotherServerSendsItsGymsBeforeTheWorkoutsThatLinkThem() async throws {
        let clock = DeviceClock("2026-10-30T12:00:00.000000Z")
        let earlier = try await Account.signUp()
        let phone = try Phone(earlier, clock: clock)
        let workouts = WorkoutRepository(context: phone.container.mainContext, now: { clock.now })
        let gym = try phone.repo.addPrivateGym(name: "Garage", address: nil)
        let listing = try phone.repo.addListing(NewListing(gymId: gym.id, kindId: "cable-station",
                                                           loads: .stack(maxKg: 90, stepKg: 5)))
        try phone.repo.makeSynced(listing: listing.id)
        let linked = Workout(startedAt: clock.now, endedAt: clock.now.addingTimeInterval(600), name: "Pull", entries: [
            WorkoutEntry(exerciseId: "bench", sets: [WorkoutSet(weightKg: 50, reps: 8, done: true)],
                         gymListingId: listing.id)], gymId: gym.id)
        try workouts.save(linked)
        await phone.engine.sync()
        #expect(phone.engine.status == .idle, "\(phone.store.syncFailures().map(\.message))")

        // The "old server" here is this Worker as another account; deleting it frees the ids, as a new server has them.
        #expect(try phone.store.moveToServer("http://moved.invalid"))
        try await earlier.deleteAccount()
        let next = try await Account.signUp()
        phone.store.ownerUserId = next.userId
        let engine = SyncEngine(store: phone.store, transport: next.transport, photos: phone.photos, now: { clock.now })
        await engine.sync()

        #expect(engine.status == .idle, "\(phone.store.syncFailures().map(\.message))")
        let pulled = try #require(try await next.transport.pullWorkouts(since: nil).first { $0.id == linked.id })
        #expect(pulled.gymId == gym.id)
        #expect(pulled.entries.first?.gymEquipmentId == listing.id)
        try await next.deleteAccount()
    }
}
```

`GymCatalogE2ETests.swift`:

```swift
import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymSync

/// Two users (and a signed-out phone, which the catalogue now turns away) against the local Worker, each on a phone of
/// their own, with the real transports and the rules from GymCore (`scripts/test-gym-e2e.sh` starts the Worker and
/// checks D1 afterwards).
@MainActor
@Suite(.enabled(if: apiConfigured, "Set API_URL (scripts/test-sync-integration.sh) to run against a local Worker"))
struct GymCatalogE2ETests {
    private nonisolated static let kinds = [
        EquipmentKind(id: "dumbbells", name: "Dumbbells", category: .freeWeight, load: .fixedSet),
        EquipmentKind(id: "adjustable-bench", name: "Adjustable bench", category: .bench, load: .none),
        EquipmentKind(id: "cable-station", name: "Cable station", category: .cable, load: .stack),
        EquipmentKind(id: "chest-press-machine", name: "Chest press", category: .machine, load: .stack),
        EquipmentKind(id: "pec-deck", name: "Pec deck", category: .machine, load: .stack),
    ]

    private nonisolated static let requirements = ExerciseRequirements(groups: [
        "c-db-press": [["dumbbells"], ["adjustable-bench"]],
        "c-machine-press": [["chest-press-machine"]],
        "c-pec-deck": [["pec-deck"]],
        "c-cable-fly": [["cable-station"]],
        "c-cable-crossover": [["cable-station"]],
        "c-pushup": [],
    ])

    private nonisolated static let exercises = [
        Exercise(id: "c-db-press", name: "Dumbbell Bench Press", bodyPart: "chest", equipment: "dumbbell",
                 target: "pectorals", secondary: ["triceps"]),
        Exercise(id: "c-machine-press", name: "Lever Chest Press", bodyPart: "chest", equipment: "leverage machine",
                 target: "pectorals", secondary: ["triceps"]),
        Exercise(id: "c-pec-deck", name: "Lever Seated Fly", bodyPart: "chest", equipment: "leverage machine",
                 target: "pectorals"),
        Exercise(id: "c-cable-fly", name: "Cable Middle Fly", bodyPart: "chest", equipment: "cable",
                 target: "pectorals", secondary: ["shoulders"]),
        Exercise(id: "c-cable-crossover", name: "Cable Crossover", bodyPart: "chest", equipment: "cable",
                 target: "pectorals", secondary: ["shoulders"]),
        Exercise(id: "c-pushup", name: "Push-Up", bodyPart: "chest", equipment: "body weight", target: "pectorals",
                 secondary: ["triceps"]),
    ]

    /// One phone: its own store, repository, catalogue client and share queue, talking to the server as `client`.
    @MainActor private struct Phone {
        let container: ModelContainer
        let repo: GymRepository
        let catalog: ApiGymCatalogTransport
        let client: GymCatalogClient
        let outbox: ShareOutbox

        init(_ api: ApiClient) throws {
            container = try GymStore.container(inMemory: true)
            repo = GymRepository(context: container.mainContext)
            catalog = ApiGymCatalogTransport(api: api)
            client = GymCatalogClient(repository: repo, transport: catalog,
                                      knownKinds: Set(GymCatalogE2ETests.kinds.map(\.id)), now: Date.init)
            outbox = ShareOutbox(repository: repo, transport: catalog,
                                 photoData: { _ in GymIntegration.jpeg }, now: Date.init)
        }

        func mapsGym(_ place: String) throws -> Gym {
            try repo.addMapsGym(placeId: place, name: "Iron Works", address: "1 Main St", latitude: 52.5,
                                longitude: 13.4)
        }

        @discardableResult
        func add(_ gym: Gym, _ kind: String, loads: ListingLoads = .stack(maxKg: 90, stepKg: 5), brand: String? = nil,
                 photo: String? = nil, notes: String? = nil) throws -> GymListing {
            try repo.addListing(NewListing(gymId: gym.id, kindId: kind, brand: brand, loads: loads, quantity: 1,
                                           notes: notes, photoFile: photo))
        }

        func record(_ id: UUID) throws -> GymListingRecord? {
            try container.mainContext.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first
        }

        func share(_ listing: GymListing, as user: UUID) async throws {
            try outbox.enqueueShare(listingId: listing.id, ownerId: user)
            await outbox.run(userId: user)
        }
    }

    // MARK: - Helpers

    private func signUp() async throws -> Account {
        let account = try Account.fresh(email: "gym-\(UUID().uuidString.lowercased())@test.local")
        try await account.auth.signUp(email: account.email, password: IntegrationEnv.password)
        return account
    }

    private func anonClient() throws -> ApiClient {
        try IntegrationEnv.config().makeClient(sessions: InMemorySessionStore())
    }

    private func place() -> String { "e2e-\(UUID().uuidString.lowercased())" }

    private func build(_ phone: Phone, _ gym: Gym) throws -> BuiltWorkout {
        let matcher = InventoryMatcher(requirements: Self.requirements, kinds: Self.kinds,
                                       inventory: try phone.repo.inventory(gymId: gym.id))
        return WorkoutBuilder(matcher: matcher, exercises: Self.exercises, history: [])
            .build(BuildRequest(muscles: [.chest], length: .medium, date: Date(timeIntervalSince1970: 20_400 * 86_400)))
    }

    /// Records a string for the shell script to look for (or not) in the tables.
    private func hand(_ role: String, _ marker: String) {
        guard let path = ProcessInfo.processInfo.environment["GYM_E2E_MARKERS_FILE"],
              let line = "\(role) \(marker)\n".data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    private func report(_ listing: UUID, as account: Account) async throws {
        try await account.catalog.report(targetType: .listing, targetId: listing, reason: .wrongInfo, note: nil)
    }

    // MARK: - Criterion 2

    @Test func criterion2AnotherUserBuildsAChestWorkoutFromSharedListingsAndASignedOutPhoneIsAskedToSignIn() async throws {
        let a = try await signUp()
        let b = try await signUp()
        let phoneA = try Phone(a.auth.api)
        let placeId = place()
        let gymA = try phoneA.mapsGym(placeId)
        let shared = try [
            phoneA.add(gymA, "dumbbells", loads: .fixed(kg: [10, 15, 20])),
            phoneA.add(gymA, "adjustable-bench", loads: .none),
            phoneA.add(gymA, "cable-station", loads: .stack(maxKg: 80, stepKg: 5)),
            phoneA.add(gymA, "chest-press-machine", loads: .stack(maxKg: 100, stepKg: 5)),
            phoneA.add(gymA, "pec-deck", loads: .stack(maxKg: 80, stepKg: 5)),
        ]
        for listing in shared { try await phoneA.share(listing, as: a.userId) }
        let sharedState = try shared.map { try #require(try phoneA.repo.listing($0.id)) }
        #expect(sharedState.allSatisfy { $0.visibility == .shared && $0.uploadState == .uploaded })
        let ids = Set(shared.map(\.id))

        // Catalogue reads need a session now (spec section 3): a signed-out phone is asked to sign in.
        let signedOut = try Phone(try anonClient())
        let anonGym = try signedOut.mapsGym(placeId)
        await #expect(throws: GymCatalogError.signedOut) {
            _ = try await signedOut.client.refresh(gymId: anonGym.id, force: true)
        }

        for (name, client) in [("user B", b.auth.api)] {
            let phone = try Phone(client)
            let gym = try phone.mapsGym(placeId)
            _ = try await phone.client.refresh(gymId: gym.id, force: true)
            let inventory = try phone.repo.inventory(gymId: gym.id)
            #expect(Set(inventory.listings.map(\.id)) == ids, "\(name) sees all five")
            let built = try build(phone, gym)
            #expect(built.items.count == 4, "\(name)")
            #expect(built.thin.isEmpty, "\(name)")
            for item in built.items {
                #expect(!item.isBodyweightFill, "\(name): \(item.exercise.exerciseId)")
                #expect(!item.match.listingIds.isEmpty, "\(name): \(item.exercise.exerciseId)")
                #expect(Set(item.match.listingIds).isSubset(of: ids), "\(name): \(item.exercise.exerciseId)")
            }
        }
        try await a.deleteAccount()
        try await b.deleteAccount()
    }

    // MARK: - Criterion 4

    @Test func criterion4ASecondShareOfTheSameKindIsKeptAsAConfirmation() async throws {
        let a = try await signUp()
        let b = try await signUp()
        let phoneA = try Phone(a.auth.api)
        let phoneB = try Phone(b.auth.api)
        let placeId = place()
        let gymA = try phoneA.mapsGym(placeId)
        let original = try phoneA.add(gymA, "cable-station")
        try await phoneA.share(original, as: a.userId)

        let gymB = try phoneB.mapsGym(placeId)
        _ = try await phoneB.client.refresh(gymId: gymB.id, force: true)
        let mine = try phoneB.add(gymB, "cable-station", loads: .stack(maxKg: 70, stepKg: 10))
        try await phoneB.share(mine, as: b.userId)

        let waiting = try #require(try phoneB.repo.listing(mine.id))
        #expect(waiting.uploadState == .waitingForChoice)
        #expect(try phoneB.outbox.duplicates(listingId: mine.id).map(\.id) == [original.id])

        _ = try phoneB.outbox.keepExisting(listingId: mine.id, existingId: original.id, ownerId: b.userId)
        await phoneB.outbox.run(userId: b.userId)
        #expect(try phoneB.repo.listing(mine.id) == nil)
        #expect(try phoneB.repo.listing(original.id)?.confirmCount == 1)

        let server = try await phoneB.catalog.publicListings(gymId: try #require(phoneB.repo.gym(gymB.id)?.remoteId)).listings
        #expect(server.map(\.id) == [original.id])
        #expect(server.first?.confirmCount == 1)
        #expect(server.first?.confirmedByMe == true)

        _ = try await phoneA.client.refresh(gymId: gymA.id, force: true)
        let theirs = try #require(try phoneA.repo.listing(original.id))
        #expect(theirs.confirmCount == 1)
        #expect(theirs.isOwn)
        try await a.deleteAccount()
        try await b.deleteAccount()
    }

    // MARK: - A lost answer

    /// Sends the first share to the real server and then drops the answer, as a connection lost on the way back does.
    private final class LosesTheFirstAnswer: GymCatalogTransport, @unchecked Sendable {
        let base: ApiGymCatalogTransport
        private let lock = NSLock()
        private var lost = false
        init(_ base: ApiGymCatalogTransport) { self.base = base }

        func publicGym(mapsPlaceId: String) async throws -> RemoteGym? { try await base.publicGym(mapsPlaceId: mapsPlaceId) }
        func publicListings(gymId: UUID) async throws -> PublicListings { try await base.publicListings(gymId: gymId) }
        func publicItems(kindId: String) async throws -> [RemoteItem] { try await base.publicItems(kindId: kindId) }
        func findOrCreateGym(mapsPlaceId: String, name: String, address: String?, latitude: Double?,
                             longitude: Double?) async throws -> UUID {
            try await base.findOrCreateGym(mapsPlaceId: mapsPlaceId, name: name, address: address, latitude: latitude,
                                           longitude: longitude)
        }
        func share(_ request: ShareRequest) async throws -> ShareResult {
            let result = try await base.share(request)
            let first = lock.withLock { () -> Bool in defer { lost = true }; return !lost }
            if first { throw GymCatalogError.offline }
            return result
        }
        func confirm(listingId: UUID) async throws -> Int { try await base.confirm(listingId: listingId) }
        func uploadSharedPhoto(_ data: Data, name: String) async throws -> String {
            try await base.uploadSharedPhoto(data, name: name)
        }
        func deleteSharedPhoto(path: String) async throws { try await base.deleteSharedPhoto(path: path) }
        func deleteAllPhotos() async throws { try await base.deleteAllPhotos() }
        func detachAllPhotos() async throws { try await base.detachAllPhotos() }
        func report(targetType: GymTargetType, targetId: UUID, reason: ReportReason, note: String?) async throws {
            try await base.report(targetType: targetType, targetId: targetId, reason: reason, note: note)
        }
        func blockAuthor(targetType: GymTargetType, targetId: UUID) async throws {
            try await base.blockAuthor(targetType: targetType, targetId: targetId)
        }
        func unblockAll() async throws -> Int { try await base.unblockAll() }
        func isAdmin() async throws -> Bool { try await base.isAdmin() }
        func moderationQueue() async throws -> [ModerationEntry] { try await base.moderationQueue() }
        func moderate(targetType: GymTargetType, targetId: UUID, action: ModerationAction) async throws -> String? {
            try await base.moderate(targetType: targetType, targetId: targetId, action: action)
        }
        func moderationPhotoDeleted(path: String) async throws { try await base.moderationPhotoDeleted(path: path) }
        func publicPhotoURL(path: String) -> URL? { base.publicPhotoURL(path: path) }
    }

    @Test func aShareWhoseAnswerWasLostIsRetriedIntoOneListing() async throws {
        let account = try await signUp()
        let phone = try Phone(account.auth.api)
        let flaky = LosesTheFirstAnswer(phone.catalog)
        let outbox = ShareOutbox(repository: phone.repo, transport: flaky,
                                 photoData: { _ in GymIntegration.jpeg }, now: Date.init)
        let gym = try phone.mapsGym(place())
        let listing = try phone.add(gym, "cable-station", photo: "mine.jpg")
        try outbox.enqueueShare(listingId: listing.id, ownerId: account.userId)

        await outbox.run(userId: account.userId)
        #expect(outbox.pendingCount == 1, "the answer was lost, so the share is still queued")
        let photo = try #require(try phone.record(listing.id)?.remotePhotoPath)
        let serverGym = try #require(try phone.repo.gym(gym.id)?.remoteId)

        await outbox.run(userId: account.userId)
        #expect(outbox.pendingCount == 0)
        #expect(try phone.record(listing.id)?.uploadStateRaw == UploadState.uploaded.rawValue)
        #expect(try phone.record(listing.id)?.remotePhotoPath == photo, "the photo is not uploaded twice")
        let onServer = try await phone.catalog.publicListings(gymId: serverGym).listings
        #expect(onServer.map(\.id) == [listing.id], "one row on the server")
        try await account.deleteAccount()
    }

    // MARK: - Borrowed photo

    @Test func aListingWithoutAPhotoBorrowsOneFromTheCatalogueUntilItIsFlagged() async throws {
        let a = try await signUp()
        let b = try await signUp()
        let c = try await signUp()
        let d = try await signUp()
        let phoneA = try Phone(a.auth.api)
        let phoneB = try Phone(b.auth.api)
        let gymA = try phoneA.mapsGym(place())
        let withPhoto = try phoneA.add(gymA, "cable-station", brand: "E2E Hammer", photo: "a.jpg")
        try await phoneA.share(withPhoto, as: a.userId)
        let photoName = try #require(try phoneA.repo.listing(withPhoto.id).flatMap { _ in
            try phoneA.container.mainContext.fetch(FetchDescriptor<GymListingRecord>()).first?.remotePhotoPath
        })

        let gymB = try phoneB.mapsGym(place())
        let without = try phoneB.add(gymB, "cable-station", brand: "E2E Hammer")
        try await phoneB.share(without, as: b.userId)
        let serverB = try await phoneB.catalog.publicListings(gymId: try #require(phoneB.repo.gym(gymB.id)?.remoteId)).listings
        #expect(serverB.first?.photoPath == nil, "share_listing with no photo stores none")

        _ = try await phoneB.client.refresh(gymId: gymB.id, force: true)
        let borrowed = try #require(try phoneB.repo.listing(without.id)).item
        #expect(borrowed.catalogPhotoPath == photoName)
        #expect(borrowed.catalogPhotoListingId == withPhoto.id)
        #expect(try phoneB.repo.listing(without.id)?.photoFile == nil)

        let url = try #require(phoneB.catalog.publicPhotoURL(path: photoName))
        let (_, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")

        for reporter in [b, c, d] { try await report(withPhoto.id, as: reporter) }
        _ = try await phoneB.client.refresh(gymId: gymB.id, force: true)
        let after = try #require(try phoneB.repo.listing(without.id)).item
        #expect(after.catalogPhotoPath == nil)
        #expect(after.catalogPhotoListingId == nil)

        try? await a.catalog.deleteSharedPhoto(path: photoName)
        for account in [a, b, c, d] { try await account.deleteAccount() }
    }

    // MARK: - Criterion 6

    @Test func criterion6AThisPhoneOnlyGymAndListingNeverReachAnyTable() async throws {
        let a = try await signUp()
        let tag = UUID().uuidString.lowercased()
        let phone = try Phone(a.auth.api)
        let deviceGym = "e2e-private-gym-\(tag)", deviceNote = "e2e-private-note-\(tag)"
        let deviceBrand = "e2e-private-brand-\(tag)", mapsNote = "e2e-maps-note-\(tag)"
        let syncedGym = "e2e-synced-gym-\(tag)"

        let home = try phone.repo.addPrivateGym(name: deviceGym, address: "e2e-private-address-\(tag)")
        try phone.add(home, "cable-station", brand: deviceBrand, photo: "a.jpg", notes: deviceNote)
        let maps = try phone.mapsGym(place())
        try phone.add(maps, "cable-station", notes: mapsNote)
        // The control: the same machinery must carry a synced gym, or an empty result below would prove nothing.
        let synced = try phone.repo.addPrivateGym(name: syncedGym, address: nil)
        try phone.repo.makeSynced(gym: synced.id)

        let defaults = UserDefaults(suiteName: "gym-e2e-\(tag)")!
        defer { UserDefaults.standard.removePersistentDomain(forName: "gym-e2e-\(tag)") }
        let store = SyncStore(context: phone.container.mainContext, defaults: defaults)
        let engine = SyncEngine(store: store, transport: ApiSyncTransport(api: a.auth.api))
        await engine.sync()
        await phone.outbox.run(userId: a.userId)
        _ = try await phone.client.refresh(gymId: home.id, force: true)
        _ = try await phone.client.refresh(gymId: maps.id, force: true)
        await engine.sync()

        for marker in [deviceGym, deviceNote, deviceBrand, mapsNote, "e2e-private-address-\(tag)"] {
            hand("absent", marker)
        }
        hand("present", syncedGym)
        let own = try #require(try phone.repo.listing(try phone.repo.listings(gymId: home.id).first!.id))
        #expect(own.visibility == .device)
        #expect(own.photoFile == "a.jpg")
        #expect(try phone.repo.listings(gymId: maps.id).first?.visibility == .device)
        // The account stays: deleting it would remove the control row too. The script reads the tables, then removes
        // every gym-*@test.local user.
    }
}
```

- [ ] **Step 4: Admins, and the gym tables, in the integration script**

In `scripts/test-sync-integration.sh`, after `start_test_server`, add:

```bash

# GymModerationIntegrationTests: accounts named sync-admin-*@test.local become admins when they sign up, in this
# throwaway D1 only (never a migration).
(cd "$ROOT/server" && npx wrangler d1 execute gymrollins --local --persist-to "$TEST_API_STATE" --command \
  "CREATE TRIGGER test_admins AFTER INSERT ON \"user\" WHEN NEW.email LIKE 'sync-admin-%@test.local' BEGIN INSERT INTO app_admins (user_id, created_at) VALUES (NEW.id, strftime('%Y-%m-%dT%H:%M:%f', 'now') || '000Z'); END") \
  > /dev/null
```

and replace the last line of the `left=$(test_d1_count "select …` sum,
`  + (select count(*) from bodyweight where user_id in ($ids)) as n")`, with:

```bash
  + (select count(*) from bodyweight where user_id in ($ids))
  + (select count(*) from gyms where owner_id in ($ids) or created_by in ($ids))
  + (select count(*) from gym_equipment where owner_id in ($ids) or added_by in ($ids))
  + (select count(*) from equipment_items where created_by in ($ids))
  + (select count(*) from photo_objects where owner_id in ($ids))
  + (select count(*) from equipment_confirmations where user_id in ($ids))
  + (select count(*) from reports where reporter_id in ($ids))
  + (select count(*) from user_blocks where blocker_id in ($ids) or blocked_id in ($ids))
  + (select count(*) from gym_unblocks where user_id in ($ids))
  + (select count(*) from app_admins where user_id in ($ids)) as n")
```

Change its header's last sentence to `The Supabase-only suites left (proposals, Claude's grants) are parked until plan
29.`

- [ ] **Step 5: The gym E2E on its own throwaway Worker**

Replace `scripts/test-gym-e2e.sh` with:

```bash
#!/usr/bin/env bash
# Shared gym catalogue end to end: two users with the real transports, against a throwaway LOCAL Worker
# (scripts/test-server.sh: port 8788, a state folder of its own, removed afterwards; never the development data).
# Afterwards, D1 is searched for every marker the Swift suite recorded: "This phone only" text must never have reached
# a gym, a listing or an item, and the control must have.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/test-server.sh
source "$ROOT/scripts/test-server.sh"

MARKERS_FILE="$(mktemp -t gym-e2e-markers)"
cleanup() {
  local status=$?
  rm -f "$MARKERS_FILE"
  stop_test_server
  exit "$status"
}
trap cleanup EXIT
start_test_server

export API_URL="$TEST_API_URL" GYM_E2E_MARKERS_FILE="$MARKERS_FILE"
(cd "$ROOT/ios/Packages/GymSync" && swift test --filter GymCatalogE2ETests)

# Criterion 6: each marker in every text column that could hold it. instr(), because D1 refuses LIKE patterns over
# 50 bytes, and a marker is longer. The photo rules over HTTP are server/test/photos.test.ts's now.
count_rows() {
  test_d1_count "select
      (select count(*) from gyms
        where instr(name || '|' || coalesce(address, '') || '|' || coalesce(maps_place_id, ''), '$1') > 0)
    + (select count(*) from gym_equipment
        where instr(coalesce(notes, '') || '|' || coalesce(private_brand, '') || '|' || coalesce(private_model, ''), '$1') > 0)
    + (select count(*) from equipment_items
        where instr(coalesce(brand, '') || '|' || coalesce(model, ''), '$1') > 0) as n"
}
absent=0; present=0
while read -r role marker; do
  [[ "$marker" =~ ^e2e-[a-z-]+-[0-9a-f-]{36}$ ]] || { echo "Unexpected marker: $marker" >&2; exit 1; }
  found=$(count_rows "$marker")
  case "$role" in
    absent) [[ "$found" == "0" ]] || { echo "FAIL: '$marker' is in $found shared row(s)" >&2; exit 1; }; absent=$((absent + 1)) ;;
    present) [[ "$found" != "0" ]] || { echo "FAIL: control '$marker' never reached the server" >&2; exit 1; }; present=$((present + 1)) ;;
  esac
done < "$MARKERS_FILE"
[[ "$absent" -gt 0 && "$present" -gt 0 ]] || { echo "FAIL: no markers were recorded ($absent absent, $present present)" >&2; exit 1; }
echo "Stays on the phone verified: $absent markers absent from gyms, gym_equipment, equipment_items; $present control present"
```

In `scripts/test-all.sh`, replace plan 27's `GYM_E2E` block with:

```bash
# Gyms shared between two users, on a throwaway local Worker (no Docker): opt in with GYM_E2E=1.
if [[ "${GYM_E2E:-0}" == "1" ]]; then
  echo "==> Shared gym catalogue E2E (throwaway local Worker on :8788)"
  "$ROOT/scripts/test-gym-e2e.sh"
fi
```

- [ ] **Step 6: Run them**

```bash
scripts/test-sync-integration.sh
GYM_E2E=1 scripts/test-gym-e2e.sh
```

Expected (leave the dev Worker alone; the scripts need port 8788 free):
- the first ends `Test run with 39 tests in 9 suites passed` and `Account deletion verified: N deleted users, 0 rows
  left`;
- the second ends `Stays on the phone verified: … markers absent …; … control present`.

Plan 27's suites are 15 of the 39. The rest are this task's: 3 in account photos, 1 in moderation, 9 in the catalogue,
6 in private gyms and 5 in the E2E.

- [ ] **Step 7: Commit**

```bash
git add ios/Packages/GymSync scripts/test-sync-integration.sh scripts/test-gym-e2e.sh scripts/test-all.sh
git commit -m "test(sync): the gym, photo and moderation suites on the Worker"
```

- [ ] **Step 8: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** spec section 8 (the same suites, on `wrangler dev`) and decision 25. Every check the parked
   suites made is still made, or was replaced by its signed-out counterpart.
2. **Quality:** the `code-reviewer` agent.
3. **Security:** the `security-reviewer` agent:
   - the admin trigger exists only in the throwaway D1;
   - every script refuses to run without its own Worker;
   - nothing is written to `server/.wrangler/state`.

---

### Task 17: The server-move check, with gym links in D1

Plan 27's check compares counts and the phone's records. Its decision 12 left D1's gym links to this plan. Gyms now
sync, so the check also compares private gyms, private listings, and the workouts and entries that link them.

**Files:**
- Modify: `scripts/server-move-check.sh`

- [ ] **Step 1: Count the gyms and their links**

In `scripts/server-move-check.sh`, add to `CHECKS` after the `muscle targets` line:

```bash
  "private gyms|select count(*) from ZGYMRECORD where ZVISIBILITYRAW = 'synced'|select count(*) as n from gyms where visibility = 'private'"
  "private listings|select count(*) from ZGYMLISTINGRECORD where ZVISIBILITYRAW = 'synced'|select count(*) as n from gym_equipment where visibility = 'private'"
  "workouts at a gym|select count(*) from ZWORKOUTRECORD w join ZGYMRECORD g on g.ZID = w.ZGYMID where w.ZISACTIVE = 0 and g.ZVISIBILITYRAW = 'synced'|select count(*) as n from workouts where gym_id is not null"
  "entries at a listing|select count(*) from ZWORKOUTENTRYRECORD e join ZGYMLISTINGRECORD l on l.ZID = e.ZGYMLISTINGID join ZWORKOUTRECORD w on e.ZWORKOUT = w.Z_PK where w.ZISACTIVE = 0 and l.ZVISIBILITYRAW = 'synced'|select count(*) as n from workout_entries where gym_equipment_id is not null"
```

Only links to synced gyms and listings ever leave the phone (plan 27, decision 12); "This phone only" ones stay local.
So the phone's side counts those, and D1's counts every link it kept.

In the `unsynced=` sum, add before its closing `")"`:

```bash
  + (select count(*) from ZGYMRECORD where ZVISIBILITYRAW = 'synced' and ZDIRTY = 1)
  + (select count(*) from ZGYMLISTINGRECORD where ZVISIBILITYRAW = 'synced' and ZDIRTY = 1)
```

- [ ] **Step 2: Run the check**

Use a fresh copy of the phone's store, as plan 27's Task 10 says (backup steps there), outside the repo. Then:

```bash
scripts/server-move-check.sh <phone-backup-dir> <work-dir>
```

Expected:
- every line equal between the phone and D1;
- `Records still unsynced on the phone: 0`, `Stores match apart from sync state.`, `Server move verified.`.

The owner's copy has one gym, "This phone only", so the four new lines read 0 and 0. That the links themselves arrive
is shown by Task 16's `aPhoneMovedFromAnotherServerSendsItsGymsBeforeTheWorkoutsThatLinkThem`. Write the printed
counts (numbers only) into this plan's Outcome, then remove the work folder.

- [ ] **Step 3: Commit**

```bash
git add scripts/server-move-check.sh
git commit -m "test(app): the server-move check counts private gyms, listings and their links"
```

- [ ] **Step 4: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** spec section 8's server-move check and plan 27's decision 12.
2. **Security:** the `security-reviewer` agent. As in plan 27, the copies stay outside the repo, and only counts are
   printed.

---

### Task 18: Finish

- [ ] **Step 1: Run everything this plan touched**

```bash
cd server && npx vitest run && npx tsc --noEmit && cd ..
node --test scripts/upload-photos.test.mjs
(cd ios/Packages/GymSync && swift test --filter GymSyncTests)
(cd ios/Packages/GymData && swift test)
scripts/test-sync-integration.sh
GYM_E2E=1 scripts/test-gym-e2e.sh
```

Expected:
- `Tests  284 passed (284)` and `# pass 24`;
- `Test run with 207 tests in 27 suites passed`, and 365 tests in 50 suites;
- 39 integration tests;
- the E2E's markers verified.

- [ ] **Step 2: Docs**

- In `server/README.md`, under the iOS test paragraph that plan 27 added, add: "The gym suites
  (`GymSyncIntegrationTests`, `scripts/test-gym-e2e.sh`) make `sync-admin-*@test.local` accounts admins with a
  trigger in their throwaway D1."
- In `docs/plans/2026-11-08-plan-27-ios-client-server-move.md` nothing changes. This plan's Outcome records what plan
  27 handed over and how it was closed.

- [ ] **Step 3: Commit and outcome**

```bash
git add server/README.md
git commit -m "docs: the gym suites' admins on the test Worker"
```

Then add `## Outcome` to this plan, as plan 26 did:
- commits per task;
- final counts;
- differences from the plan as written;
- what passes to plans 29 and 30: proposals and grants still parked; `SupabaseGymCatalogTransport*`,
  `SupabaseStoragePhotoProvider`'s Supabase-era tests and `SUPABASE_*` to delete; the remote R2 buckets and the
  exercise-photo upload to the deployed Worker in the Cloudflare checklist.

## Self-review of the iOS part

**Coverage** (the controller's list, and plan 27's "Handed to later plans → Plan 28"):

| Asked for | Where |
|---|---|
| `ApiGymCatalogTransport` behind the protocol, in place of `UnavailableGymCatalogTransport` | Tasks 12, 15 |
| Gym and listing sync in `ApiSyncTransport`, `servesGyms` true | Task 13 |
| Photo upload, read, delete, list, detach | Tasks 12 (shared, list, detach), 13 (private) |
| `GymCatalogErrors` from `ApiError`, code first, then status, same messages | Task 11 |
| `{id}`, `{confirm_count}`, `{cleared}`, `{admin}` | Task 12 |
| `+` as `%2B` in `?place=` | `ApiClient` (plan 27); pinned by Task 12's test, probed on the Worker |
| `PHOTO_HOSTING = storage` from `<API_URL>/photos/exercises/…` | Task 15 |
| The five parked suites, and `GYM_E2E` | Task 16 |
| The catalogue cache after a move | Task 14 (decision 23) |
| Workouts that went up before their gym (plan 27's handoff) | Task 16's move test |
| The server-move check with gym links in D1 | Task 17 |
| Both open questions | Decided (16, 17) |

**Placeholders:** none. The Swift of Tasks 11–14 and 16 is the code that compiled and passed in the scratch copy
(decision 26). The app's Swift in Task 15 and the scripts weren't run ahead; their SQL was.

**Names used across tasks:** `ApiGymCatalogTransport`, `GymCatalogRows.array(in:key:)`, `OwnedPhotos`,
`ApiSyncTransport.privatePhotoPath`, `forgetOldCatalogue`, `GymIntegration.jpeg` / `signedOutCatalog` /
`signedOutTransport` / `isServed`, `Account.catalog`, `HostedPhotoProvider`, `PhotoHostingConfig.apiURL`,
`WORKER_STATE`.
