# Plan 26: Cloudflare server and sync

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local Cloudflare Worker in `server/` signs the app in with Better Auth, using the Apple id token, or email and password in debug builds. It serves the sync API from D1 for:
- the profile,
- the plan: custom exercises, exercise preferences, routines, the week, muscle targets,
- body weight,
- workouts.

It also deletes an account. All of it keeps the rules the Postgres functions and triggers enforced.

**Architecture:**
- **Hono** routes a single Worker. Better Auth is built per request from the D1 binding, and its bearer plugin gives the app a session token.
- **The sync tables** are each described once, in `src/sync/entities.ts`, and two generic pieces serve all seven:
  - **push:** one `INSERT … SELECT … FROM json_each(?)` statement, with last-write-wins and the owner check in its `ON CONFLICT … WHERE`,
  - **pull:** a keyset query.
- **Workouts** have their own atomic batch, gated by a write token.
- **Validation is split:**
  - D1 CHECK constraints keep the value rules.
  - TypeScript checks types and normalises ids and timestamps.
  - Both answer `422 row_rejected`, as Postgres's 22xxx and 23xxx errors did.

**Tech stack:**
- TypeScript, Hono 4.13.17, and Better Auth 1.7.18 with its bearer plugin.
- Cloudflare Workers and D1 through wrangler 4.158.0.
- Vitest 4.1.12 with `@cloudflare/vitest-plugin` 1.6.0, which runs the tests in workerd against an in-memory D1.
- Node 22 or later, for the scripts.

**Spec:** `docs/specs/2026-11-07-cloudflare-backend-design.md`, sections 3, 4 (Sync, Sign-in), 6, 7 and 8.

**Branch:** `feat-cloudflare`, cut from `feat-claude-prompts`.
- No push.
- Local only: never run `wrangler login`, `wrangler deploy`, or any `wrangler` command without `--local`.
- Commit messages have no `Co-Authored-By`, `Generated with` or `Claude-Session` trailers; the owner forbids them.

**Not in this plan:**
- Gyms and gym listings in sync, photos and R2, the catalogue and moderation (plan 28).
- Proposals, the MCP server and Claude's OAuth (plan 29), which also adds its own tables: `connect_requests` and Better Auth's OAuth tables.
- Anything on iOS (plan 27).
- Removing Supabase (plan 30).
The Supabase code keeps working beside `server/` until plan 30.

---

## Decisions this plan makes

1. **One statement per push.**
   - The app sends up to 200 rows per push. The server binds them as one JSON text and upserts them with `INSERT … SELECT json_extract(value, '$.col') … FROM json_each(?1) WHERE true ON CONFLICT … DO UPDATE … WHERE … RETURNING`. That stays inside D1's 100 bound values per statement and 50 statements per request on the free plan, whatever the row count.
   - **Checked beforehand,** in local D1 and `sqlite3` 3.51:
     - only the rows actually stored come back in `RETURNING`, and they become the acks,
     - an older edit and another account's row are skipped,
     - a bad row fails the whole statement.
2. **Time.**
   - Every timestamp is stored as text in exactly one form, `YYYY-MM-DDTHH:MM:SS.ffffffZ` (UTC, six digits), so text order is time order.
   - `normalizeTimestamp` turns whatever the app's `SyncDate.parse` accepts into that form.
   - **The server's own clock** is SQLite's, `strftime('%Y-%m-%dT%H:%M:%f','now') || '000Z'` (`NOW_SQL`). It is read inside the statement that writes, and D1 runs writes one at a time, so a later write never gets an earlier `updated_at`. The Worker's `Date.now()` is not used, because it doesn't advance during a request.
   - The stamps have millisecond resolution, with `000` microseconds. The keyset tiebreak covers different rows that share one.
   - **One row's stamp still moves on every accepted write.** On update, `laterStamp` takes the clock, or one microsecond past the stored stamp when the clock hasn't moved past it.
   - **Why it matters:** the app treats "the version I last saw" as exact equality, and pulls with `updated_at > cursor`. Two writes in one millisecond would otherwise share a stamp. Postgres's microsecond `now()` made that rare, and the bump makes it impossible.
3. **Isolation.**
   - The user id only ever comes from the verified session (`c.var.userId`); no route reads one from the body.
   - For tables keyed by `id` alone (custom exercises, routines, body weight, workouts), a push that names another account's id answers `403 not_allowed` before anything is written, as Postgres's RLS did. The upsert's own `WHERE <table>.user_id = excluded.user_id` makes that safe against a race.
   - Tables keyed by `(user_id, …)` can't collide across accounts.
4. **Validation.** Each column has a kind: text, int, real, bool, json, ts, date or uuid.
   - **Kinds** (`src/sync/columns.ts`):
     - uuids are lowercased,
     - booleans are stored as 0 and 1, and come back as `true`/`false`,
     - JSON is stored as text and comes back parsed.
   - **Ranges, lists and lengths** stay in the D1 CHECKs.
   - **Errors:**
     - a wrong type answers `422 row_rejected` with `rows[i].column` in the message,
     - a CHECK, NOT NULL, FOREIGN KEY or UNIQUE failure answers `422 row_rejected` with SQLite's message,
     - the app (plan 27) turns both into `SyncRecordRejected`, as it did with SQLSTATE 22/23.
5. **The workout save.**
   - **Ported line by line from `upsert_workout`** (`20261030000005_workout_gym_links.sql`). A read first answers `stale` exactly where Postgres did.
   - **The write is one D1 batch,** which runs as a transaction:
     - the upsert, which stamps a fresh `write_id`,
     - delete the entries,
     - insert entries,
     - insert sets,
     - read back.
   - **The guards:**
     - The upsert repeats the stale conditions in its `WHERE`.
     - Entries and sets are written only `WHERE EXISTS (… write_id = this save's)`, so a save that lost a race changes nothing and answers `stale`.
   - `write_id` is a new column on `workouts` that is never sent to the app.
6. **Gym links on workouts.** The rules are those of `upsert_workout` and its two triggers, with one deliberate difference.
   - Postgres kept a link the phone sent again to a gym that has since been removed, because its trigger only re-checks a changed id. The comment above `upsert_workout` says such a link "becomes null … whether or not the phone sent the link again".
   - This plan follows the comment: a re-sent link is kept only while it survives.
   - The visibility rules live in `src/gyms/visibility.ts`, so plans 28 and 29 reuse them.
7. **Account deletion** is `delete_my_account`, in one D1 batch.
   - Each statement carries `NOT EXISTS (SELECT 1 FROM photo_objects WHERE owner_id = ?1)`, so a photo that lands mid-way stops all of them, and the route answers `photos_remain`.
   - The Postgres trigger that recounted `confirm_count` when confirmations cascaded away becomes an explicit recount before the user row goes.
8. **Tests:**
   - **Storage.** `@cloudflare/vitest-plugin` gives each test file its own in-memory D1, with the migrations applied by `test/apply-migrations.ts`. Tests therefore never touch the `wrangler dev` state in `server/.wrangler/`.
   - **Apple sign-in** is tested with a locally signed RS256 token and a spy on `fetch` that answers Apple's key URL. Better Auth's real verification runs: audience, nonce, signature and expiry.
9. **Packages:**
   - `@cloudflare/vitest-pool-workers` was renamed to `@cloudflare/vitest-plugin` and has a new config API (`cloudflareTest()`).
   - There's no `@better-auth/cli` for 1.7, so `scripts/gen-auth-schema.mjs` writes Better Auth's tables with its own `getMigrations` against an in-memory `node:sqlite`.
   - npm's resolver fails on the vitest peer tree, so `server/.npmrc` sets `legacy-peer-deps=true`.
10. **Code style** matches `supabase/functions` (plan 29 moves that code here):
    - no semicolons, single quotes, two-space indent, lines up to 110 characters,
    - relative imports end in `.ts` (`allowImportingTsExtensions`).
11. **Ack ids are the row's key as text.**
    - The profile's is its `user_id`; the app (plan 27) uses its own fixed profile id instead, as it does today.
    - The week's is the weekday number as text (`"1"` to `"7"`).
12. **Seeds.** `scripts/gen-exercise-seed.mjs` and `scripts/gen-equipment-seed.mjs` write the D1 seeds beside the Postgres ones, and `--check` compares both. Plan 30 drops the Postgres output.

## File map

| File | Responsibility |
|---|---|
| `server/package.json`, `.npmrc`, `package-lock.json` | Pinned dependencies; `npm test`, `npm run typecheck`, `npm run dev` |
| `server/tsconfig.json` | Strict TypeScript for workerd; `.ts` import extensions |
| `server/wrangler.jsonc` | The Worker, its D1 binding, local vars (`127.0.0.1:8787`) |
| `server/.dev.vars.example` | Local secrets template (`.dev.vars` is gitignored) |
| `server/vitest.config.ts`, `test/apply-migrations.ts`, `test/env.d.ts` | Tests in workerd with migrated in-memory D1 |
| `server/scripts/gen-auth-schema.mjs` | Writes `migrations/0001_better_auth.sql` from Better Auth's schema |
| `server/migrations/0001_better_auth.sql` | Better Auth's `user`, `session`, `account`, `verification` |
| `server/migrations/0002_app_schema.sql` | The 24 app tables plus `gym_unblocks` and `photo_objects`, translated from Postgres |
| `server/migrations/0003_seed_exercises.sql`, `0004_seed_equipment.sql` | Generated seeds (exercise library, equipment catalogue) |
| `server/src/env.ts` | `Env` (bindings) and `AppEnv` (Hono types) |
| `server/src/index.ts` | The Hono app: auth, `/v1` behind the session, errors |
| `server/src/http/errors.ts` | `ApiError`, the `{error:{code,message}}` body, D1 constraint errors as `row_rejected` |
| `server/src/http/body.ts` | Reading a JSON body |
| `server/src/auth/auth.ts` | `createAuth(env)`: Better Auth with Apple, bearer, debug email |
| `server/src/auth/session.ts` | `requireUser`: the session's user id, or 401 `signed_out` |
| `server/src/sync/time.ts` | `normalizeTimestamp`, `NOW_SQL`, `laterStamp` |
| `server/src/sync/columns.ts` | Column kinds; app JSON → stored value → app JSON; `RowError` |
| `server/src/sync/entities.ts` | The seven synced tables, described once |
| `server/src/sync/table-sync.ts` | Generic push (upsert + acks) and pull (keyset pages) |
| `server/src/gyms/visibility.ts` | Who can read or keep a link to a gym or listing |
| `server/src/sync/gym-links.ts` | A workout's gym and its entries' listings on save |
| `server/src/sync/workouts.ts` | Workout save (stale, retry, force, atomic batch), pull and fetch |
| `server/src/sync/routes.ts` | `/v1/sync/*` |
| `server/src/account/delete.ts`, `routes.ts` | `DELETE /v1/account` |
| `server/test/*.test.ts`, `helpers.ts`, `samples.ts`, `apple.ts`, `gym-fixtures.ts` | Tests and their helpers |
| `scripts/gen-exercise-seed.mjs`, `gen-equipment-seed.mjs`, `gen-equipment-seed.test.mjs` | Also write and check the D1 seeds |
| `scripts/server-up.sh` | Local Worker: apply migrations to the local D1, then `wrangler dev` |
| `scripts/test-all.sh` | Runs the server tests and the D1 seed check |
| `server/README.md` | How to run and test the server |
| `.gitignore` | `server/.wrangler/`, `server/.dev.vars` |

## How to run things

```bash
cd server
npm ci                          # after Task 1 creates package-lock.json (.npmrc sets legacy-peer-deps)
npx vitest run                  # every server test; a file: npx vitest run test/sync-rows.test.ts
npx tsc --noEmit                # typecheck
cd .. && scripts/server-up.sh   # local Worker on http://127.0.0.1:8787 (needs server/.dev.vars)
```

Expected test output ends with `Test Files  N passed (N)` and `Tests  M passed (M)`. Vitest prints a node `punycode`
DEP0040 warning at start-up; ignore it.

---

### Task 1: The Worker skeleton

**Files:**
- Create: `server/package.json`, `server/.npmrc`, `server/tsconfig.json`, `server/wrangler.jsonc`, `server/vitest.config.ts`,
  `server/.dev.vars.example`, `server/migrations/.gitkeep`, `server/src/env.ts`, `server/src/http/errors.ts`,
  `server/src/index.ts`, `server/test/env.d.ts`, `server/test/apply-migrations.ts`, `server/test/helpers.ts`
- Modify: `.gitignore`
- Test: `server/test/app.test.ts`, `server/test/errors.test.ts`

- [ ] **Step 1: Write the project files**

`server/package.json`:

```json
{
  "name": "gymrollins-server",
  "version": "0.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "wrangler dev --local",
    "test": "vitest run",
    "typecheck": "tsc --noEmit",
    "gen:auth-schema": "node scripts/gen-auth-schema.mjs > migrations/0001_better_auth.sql"
  },
  "dependencies": {
    "better-auth": "1.7.18",
    "hono": "4.13.17"
  },
  "devDependencies": {
    "@cloudflare/vitest-plugin": "1.6.0",
    "@cloudflare/workers-types": "5.20261107.1",
    "@types/node": "22.15.17",
    "typescript": "5.9.3",
    "vitest": "4.1.12",
    "wrangler": "4.158.0"
  }
}
```

`server/.npmrc` (npm's resolver crashes on vitest's peer tree, `Cannot read properties of null (reading 'edgesOut')`):

```
legacy-peer-deps=true
```

`server/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "bundler",
    "lib": ["ES2022"],
    "types": ["@cloudflare/workers-types", "@cloudflare/vitest-plugin/types", "vite/client"],
    "strict": true,
    "noEmit": true,
    "allowImportingTsExtensions": true,
    "skipLibCheck": true,
    "resolveJsonModule": true
  },
  "include": ["src", "test", "vitest.config.ts"]
}
```

`server/wrangler.jsonc`:

```jsonc
// The GymRollins API: one Worker with D1 (R2 comes in plan 28). Local only: `wrangler dev --local` and
// `wrangler d1 migrations apply gymrollins --local` need no Cloudflare account. The deploy (owner's approval) replaces
// database_id and sets BETTER_AUTH_SECRET with `wrangler secret put`.
{
  "name": "gymrollins",
  "main": "src/index.ts",
  "compatibility_date": "2026-11-01",
  "compatibility_flags": ["nodejs_compat"],
  "vars": {
    "ALLOW_PASSWORD_AUTH": "0",
    "APPLE_BUNDLE_ID": "com.rollins.gymrollins",
    "PUBLIC_BASE_URL": "http://127.0.0.1:8787"
  },
  "d1_databases": [
    {
      "binding": "DB",
      "database_name": "gymrollins",
      "database_id": "00000000-0000-0000-0000-000000000000",
      "migrations_dir": "migrations"
    }
  ],
  "dev": { "ip": "127.0.0.1", "port": 8787 }
}
```

`server/vitest.config.ts`:

```ts
import path from 'node:path'
import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-plugin'
import { defineConfig } from 'vitest/config'

// Tests run in workerd with an in-memory D1 per test file (never server/.wrangler/state), migrated by
// test/apply-migrations.ts. These bindings override wrangler.jsonc's vars.
export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, 'migrations'))
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: './wrangler.jsonc' },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            ALLOW_PASSWORD_AUTH: '1',
            BETTER_AUTH_SECRET: 'test-secret-test-secret-test-secret-000001',
            APPLE_BUNDLE_ID: 'com.rollins.gymrollins',
            PUBLIC_BASE_URL: 'http://localhost',
          },
        },
      }),
    ],
    test: { setupFiles: ['./test/apply-migrations.ts'] },
  }
})
```

`server/.dev.vars.example`:

```
# Copy to server/.dev.vars (gitignored) for scripts/server-up.sh. Local only: the deployed Worker gets its secret from
# `wrangler secret put BETTER_AUTH_SECRET`, and never turns on password sign-in.
BETTER_AUTH_SECRET=replace-with-at-least-32-random-characters
# Email and password sign-in, for the integration and UI tests against the local Worker.
ALLOW_PASSWORD_AUTH=1
```

`server/migrations/.gitkeep`: an empty file (Task 2 adds the first migration).

`server/test/env.d.ts`:

```ts
import type { D1Migration } from 'cloudflare:test'
import type { Env as ServerEnv } from '../src/env.ts'

declare global {
  namespace Cloudflare {
    interface Env extends ServerEnv {
      TEST_MIGRATIONS: D1Migration[]
    }
  }
}

export {}
```

`server/test/apply-migrations.ts`:

```ts
import { applyD1Migrations } from 'cloudflare:test'
import { env } from 'cloudflare:workers'

await applyD1Migrations(env.DB, env.TEST_MIGRATIONS)
```

Append to `.gitignore`, after the `# Supabase` block:

```
# Cloudflare Worker (server/): local D1/R2 state and local secrets
server/.wrangler/
server/.dev.vars
```

- [ ] **Step 2: Install**

Run: `cd server && npm install`
Expected: `added … packages`, a new `server/package-lock.json`, no `ERR!`.

- [ ] **Step 3: Write the failing tests**

`server/test/helpers.ts`:

```ts
import { env } from 'cloudflare:workers'
import app from '../src/index.ts'

export const ORIGIN = 'http://localhost'

interface Options {
  token?: string
  /** JSON-encoded unless it is already a string. */
  body?: unknown
}

/** A request as the app makes it: JSON, the session token as a bearer, and no Origin header. */
export function request(method: string, path: string, options: Options = {}): Promise<Response> {
  const headers: Record<string, string> = {}
  if (options.token) headers.authorization = `Bearer ${options.token}`
  let body: string | undefined
  if (options.body !== undefined) {
    headers['content-type'] = 'application/json'
    body = typeof options.body === 'string' ? options.body : JSON.stringify(options.body)
  }
  return Promise.resolve(app.fetch(new Request(`${ORIGIN}${path}`, { method, headers, body }), env))
}
```

`server/test/app.test.ts`:

```ts
import { describe, expect, it } from 'vitest'
import { request } from './helpers.ts'

describe('the Worker', () => {
  it('answers an unknown route with a JSON 404', async () => {
    const res = await request('GET', '/nowhere')
    expect(res.status).toBe(404)
    expect(await res.json()).toEqual({ error: { code: 'not_found', message: 'No such route.' } })
  })
})
```

`server/test/errors.test.ts`:

```ts
import { describe, expect, it } from 'vitest'
import { constraintMessage } from '../src/http/errors.ts'

describe('constraintMessage', () => {
  it('reads a D1 constraint failure as the row being refused', () => {
    const check = new Error('D1_ERROR: CHECK constraint failed: rest_sec BETWEEN 0 AND 900: SQLITE_CONSTRAINT')
    expect(constraintMessage(check)).toBe('CHECK constraint failed: rest_sec BETWEEN 0 AND 900')
    expect(constraintMessage(new Error('D1_ERROR: FOREIGN KEY constraint failed'))).toBe('FOREIGN KEY constraint failed')
    expect(constraintMessage(new Error('UNIQUE constraint failed: workout_sets.id'))).toBe(
      'UNIQUE constraint failed: workout_sets.id',
    )
  })

  it('leaves other errors alone', () => {
    expect(constraintMessage(new Error('D1_ERROR: no such table: nope'))).toBeNull()
  })
})
```

- [ ] **Step 4: Run them to see them fail**

Run: `cd server && npx vitest run`
Expected: FAIL. `Failed to load url ../src/index.ts` (or `Cannot find module`), because `src/` doesn't exist yet.

- [ ] **Step 5: Write the skeleton**

`server/src/env.ts`:

```ts
/** The Worker's bindings and vars (wrangler.jsonc; secrets in server/.dev.vars locally). */
export interface Env {
  DB: D1Database
  BETTER_AUTH_SECRET: string
  /** The audience of Apple's id tokens for the app. */
  APPLE_BUNDLE_ID: string
  /** The address the Worker is reached at: Better Auth's base URL. */
  PUBLIC_BASE_URL: string
  /** "1" turns on email and password sign-in: debug builds and tests only. */
  ALLOW_PASSWORD_AUTH?: string
}

export interface AppEnv {
  Bindings: Env
  Variables: { userId: string }
}
```

`server/src/http/errors.ts`:

```ts
import type { Context } from 'hono'

/** The statuses the API answers errors with (spec section 6). */
export type ErrorStatus = 400 | 401 | 403 | 404 | 409 | 413 | 422 | 429 | 500

/**
 * An error the app is told about, as `{"error": {"code", "message"}}`. Codes keep the strings the app already maps
 * (row_rejected, not_allowed, photos_remain, …), so its messages don't change.
 */
export class ApiError extends Error {
  constructor(readonly status: ErrorStatus, readonly code: string, message: string) {
    super(message)
  }
}

export function errorBody(code: string, message: string) {
  return { error: { code, message } }
}

const CONSTRAINT = /(CHECK|NOT NULL|FOREIGN KEY|UNIQUE) constraint failed/

/** SQLite's message when D1 refused a row's data (what Postgres raised as 22xxx/23xxx), or null. */
export function constraintMessage(error: unknown): string | null {
  const message = error instanceof Error ? error.message : String(error)
  if (!CONSTRAINT.test(message)) return null
  return message.replace(/^D1_ERROR:\s*/, '').replace(/:\s*SQLITE_CONSTRAINT\S*$/, '')
}

export function onError(error: Error, c: Context): Response {
  if (error instanceof ApiError) return c.json(errorBody(error.code, error.message), error.status)
  const constraint = constraintMessage(error)
  if (constraint !== null) return c.json(errorBody('row_rejected', constraint), 422)
  console.error('unhandled', error)
  return c.json(errorBody('server_error', 'Something went wrong.'), 500)
}
```

`server/src/index.ts`:

```ts
// The GymRollins API (docs/specs/2026-11-07-cloudflare-backend-design.md): one Worker, with Better Auth under /api/auth
// and the app's routes under /v1 behind its session.
import { Hono } from 'hono'
import type { AppEnv } from './env.ts'
import { errorBody, onError } from './http/errors.ts'

const app = new Hono<AppEnv>()
app.onError(onError)
app.notFound((c) => c.json(errorBody('not_found', 'No such route.'), 404))

export default app
```

- [ ] **Step 6: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  2 passed (2)`, `Tests  3 passed (3)`, then no output from `tsc`.

- [ ] **Step 7: Commit**

```bash
git add .gitignore server
git commit -m "feat(server): Worker skeleton with JSON errors"
```

### Task 2: Sign-in with Better Auth

**Files:**
- Create: `server/scripts/gen-auth-schema.mjs`, `server/migrations/0001_better_auth.sql` (generated),
  `server/src/auth/auth.ts`, `server/test/apple.ts`
- Modify: `server/src/index.ts`, `server/test/helpers.ts`
- Delete: `server/migrations/.gitkeep`
- Test: `server/test/auth.test.ts`

- [ ] **Step 1: Write the failing tests**

Append to `server/test/helpers.ts`:

```ts
/** A new account by email and password (on in tests: ALLOW_PASSWORD_AUTH=1). */
export async function signUp(): Promise<{ token: string; userId: string }> {
  const email = `t-${crypto.randomUUID()}@test.local`
  const res = await request('POST', '/api/auth/sign-up/email', {
    body: { email, password: 'correct-horse-battery', name: 'Test' },
  })
  if (res.status !== 200) throw new Error(`sign-up failed: ${res.status} ${await res.text()}`)
  const body = await res.json<{ token: string; user: { id: string } }>()
  return { token: body.token, userId: body.user.id }
}
```

`server/test/apple.ts`:

```ts
import { vi } from 'vitest'

export interface AppleKeys {
  privateKey: CryptoKey
  jwk: JsonWebKey & { kid: string }
}

const base64url = (bytes: ArrayBuffer | string) =>
  btoa(typeof bytes === 'string' ? bytes : String.fromCharCode(...new Uint8Array(bytes)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

export async function appleKeyPair(): Promise<AppleKeys> {
  const pair = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  ) as CryptoKeyPair
  const exported = await crypto.subtle.exportKey('jwk', pair.publicKey) as JsonWebKey
  return { privateKey: pair.privateKey, jwk: { ...exported, kid: crypto.randomUUID(), alg: 'RS256', use: 'sig' } }
}

/** A key pair whose public half Apple's key URL serves, through a spy on fetch: Better Auth's real check runs. */
export async function mockAppleKeys(): Promise<AppleKeys> {
  const keys = await appleKeyPair()
  const realFetch = globalThis.fetch
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const url = input instanceof Request ? input.url : String(input)
    if (url === 'https://appleid.apple.com/auth/keys') return Response.json({ keys: [keys.jwk] })
    return realFetch(input, init)
  })
  return keys
}

/** An id token as Apple signs one for the app: RS256, Apple's issuer, ten minutes. */
export async function appleIdToken(keys: AppleKeys, claims: Record<string, unknown>): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  const header = base64url(JSON.stringify({ alg: 'RS256', kid: keys.jwk.kid, typ: 'JWT' }))
  const payload = base64url(JSON.stringify({
    iss: 'https://appleid.apple.com',
    iat: now,
    exp: now + 600,
    email: `${String(claims.sub)}@privaterelay.appleid.com`,
    email_verified: 'true',
    ...claims,
  }))
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', keys.privateKey, new TextEncoder().encode(
    `${header}.${payload}`,
  ))
  return `${header}.${payload}.${base64url(signature)}`
}
```

`server/test/auth.test.ts`:

```ts
import { env } from 'cloudflare:workers'
import { getMigrations } from 'better-auth/db/migration'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createAuth, SESSION_EXPIRES_IN } from '../src/auth/auth.ts'
import { appleIdToken, appleKeyPair, mockAppleKeys, sha256Hex } from './apple.ts'
import { request, signUp } from './helpers.ts'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

afterEach(() => vi.restoreAllMocks())

async function sessionUser(token: string): Promise<string | null> {
  const body = await (await request('GET', '/api/auth/get-session', { token })).json<{ user: { id: string } } | null>()
  return body?.user.id ?? null
}

/** The app's Sign in with Apple call: Apple's id token and the raw nonce whose SHA-256 the token carries. */
async function signInWithApple(token: string, nonce: string): Promise<Response> {
  return request('POST', '/api/auth/sign-in/social', { body: { provider: 'apple', idToken: { token, nonce } } })
}

describe('the schema', () => {
  it('has every table, column and index Better Auth expects', async () => {
    const { toBeCreated, toBeAdded, toBeAddedIndexes } = await getMigrations(createAuth(env).options)
    expect(toBeCreated).toEqual([])
    expect(toBeAdded).toEqual([])
    expect(toBeAddedIndexes).toEqual([])
  })
})

describe('email and password (debug builds and tests)', () => {
  it('signs up with a UUID user id and a bearer session token', async () => {
    const { token, userId } = await signUp()
    expect(userId).toMatch(UUID)
    expect(await sessionUser(token)).toBe(userId)
  })

  it('is off unless ALLOW_PASSWORD_AUTH is 1', async () => {
    const res = await createAuth({ ...env, ALLOW_PASSWORD_AUTH: '0' }).handler(
      new Request('http://localhost/api/auth/sign-up/email', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ email: 'off@test.local', password: 'correct-horse-battery', name: 'Off' }),
      }),
    )
    expect(res.status).toBe(400)
  })
})

describe('sessions', () => {
  it('last 60 days', async () => {
    const { token } = await signUp()
    const row = await env.DB.prepare('SELECT expiresAt FROM session WHERE token = ?1').bind(token)
      .first<{ expiresAt: string }>()
    const left = new Date(row!.expiresAt).getTime() - Date.now()
    expect(Math.abs(left - SESSION_EXPIRES_IN * 1000)).toBeLessThan(60_000)
  })

  it('end on sign-out', async () => {
    const { token } = await signUp()
    expect((await request('POST', '/api/auth/sign-out', { token })).status).toBe(200)
    expect(await sessionUser(token)).toBeNull()
  })
})

describe('Sign in with Apple, with the id token the app gets', () => {
  it('signs in with the raw nonce, without an Origin header, and gives a session token', async () => {
    const keys = await mockAppleKeys()
    const idToken = await appleIdToken(keys, {
      aud: env.APPLE_BUNDLE_ID,
      sub: 'apple-1',
      nonce: await sha256Hex('raw-nonce'),
    })
    const res = await signInWithApple(idToken, 'raw-nonce')
    expect(res.status).toBe(200)
    const session = res.headers.get('set-auth-token')
    expect(session).toBeTruthy()
    expect(await sessionUser(session!)).toMatch(UUID)
  })

  it('finds the same account on the next sign-in', async () => {
    const keys = await mockAppleKeys()
    const once = async () => {
      const idToken = await appleIdToken(keys, { aud: env.APPLE_BUNDLE_ID, sub: 'apple-2', nonce: await sha256Hex('n') })
      return sessionUser((await signInWithApple(idToken, 'n')).headers.get('set-auth-token')!)
    }
    expect(await once()).toBe(await once())
  })

  it("refuses another app's token, a wrong nonce and a key Apple never published", async () => {
    const keys = await mockAppleKeys()
    const claims = { sub: 'apple-3', nonce: await sha256Hex('n') }
    const status = async (idToken: string, nonce: string) => (await signInWithApple(idToken, nonce)).status
    expect(await status(await appleIdToken(keys, { ...claims, aud: 'com.other.app' }), 'n')).toBe(401)
    expect(await status(await appleIdToken(keys, { ...claims, aud: env.APPLE_BUNDLE_ID }), 'other')).toBe(401)
    const stranger = await appleKeyPair()
    expect(await status(await appleIdToken(stranger, { ...claims, aud: env.APPLE_BUNDLE_ID }), 'n')).toBe(401)
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/auth.test.ts`
Expected: FAIL. `Failed to load url ../src/auth/auth.ts`.

- [ ] **Step 3: Write the schema generator and generate the migration**

`server/scripts/gen-auth-schema.mjs`:

```js
#!/usr/bin/env node
// Prints Better Auth's tables as SQL for D1 (npm run gen:auth-schema writes migrations/0001_better_auth.sql), offline,
// from Better Auth's own schema compiler run against an empty in-memory SQLite. There is no @better-auth/cli for 1.7.
// The options here must add the same tables as createAuth's (src/auth/auth.ts); test/auth.test.ts checks the result.
import { DatabaseSync } from 'node:sqlite'
import { getMigrations } from 'better-auth/db/migration'

const { compileMigrations } = await getMigrations({
  database: new DatabaseSync(':memory:'),
  emailAndPassword: { enabled: true },
  advanced: { database: { generateId: () => crypto.randomUUID() } },
})
console.log(await compileMigrations())
```

Run: `cd server && rm migrations/.gitkeep && npm run gen:auth-schema`
Expected: `migrations/0001_better_auth.sql` holds exactly the following. A `node:sqlite` ExperimentalWarning on stderr is fine.

```sql
create table "user" ("id" text not null primary key, "name" text not null, "email" text not null unique, "emailVerified" integer not null, "image" text, "createdAt" date not null, "updatedAt" date not null);

create table "session" ("id" text not null primary key, "expiresAt" date not null, "token" text not null unique, "createdAt" date not null, "updatedAt" date not null, "ipAddress" text, "userAgent" text, "userId" text not null references "user" ("id") on delete cascade);

create table "account" ("id" text not null primary key, "accountId" text not null, "providerId" text not null, "userId" text not null references "user" ("id") on delete cascade, "accessToken" text, "refreshToken" text, "idToken" text, "accessTokenExpiresAt" date, "refreshTokenExpiresAt" date, "scope" text, "password" text, "createdAt" date not null, "updatedAt" date not null);

create table "verification" ("id" text not null primary key, "identifier" text not null, "value" text not null, "expiresAt" date not null, "createdAt" date not null, "updatedAt" date not null);

create index "session_userId_idx" on "session" ("userId");

create index "account_userId_idx" on "account" ("userId");

create index "verification_identifier_idx" on "verification" ("identifier");
```

- [ ] **Step 4: Write the auth**

`server/src/auth/auth.ts`:

```ts
import { betterAuth } from 'better-auth'
import { bearer } from 'better-auth/plugins'
import type { Env } from '../env.ts'

/** Sessions last 60 days and renew once a day while the app uses them (spec section 4, Sign-in). */
export const SESSION_EXPIRES_IN = 60 * 60 * 24 * 60
export const SESSION_UPDATE_AGE = 60 * 60 * 24

/** Built per request, because the D1 binding only exists on `env`. Better Auth recognises D1 by its shape. */
export function createAuth(env: Env) {
  return betterAuth({
    database: env.DB,
    secret: env.BETTER_AUTH_SECRET,
    baseURL: env.PUBLIC_BASE_URL,
    basePath: '/api/auth',
    emailAndPassword: { enabled: env.ALLOW_PASSWORD_AUTH === '1' },
    session: { expiresIn: SESSION_EXPIRES_IN, updateAge: SESSION_UPDATE_AGE },
    advanced: { database: { generateId: () => crypto.randomUUID() } },
    socialProviders: {
      apple: {
        // Native Sign in with Apple only: the app sends Apple's id token, whose audience is the app's bundle id, and
        // the raw nonce (Better Auth accepts the token's nonce claim as the raw value or its SHA-256). There is no web
        // flow, so no Services ID and no client secret.
        clientId: env.APPLE_BUNDLE_ID,
        clientSecret: 'unused-native-id-token-only',
        appBundleIdentifier: env.APPLE_BUNDLE_ID,
      },
    },
    plugins: [bearer()],
  })
}
```

In `server/src/index.ts`, import it and mount Better Auth after `notFound`:

```ts
import { createAuth } from './auth/auth.ts'
```

```ts
app.on(['GET', 'POST'], '/api/auth/*', (c) => createAuth(c.env).handler(c.req.raw))
```

- [ ] **Step 5: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  3 passed (3)`, `Tests  11 passed (11)`, no `tsc` output.

- [ ] **Step 6: Commit**

```bash
git add server
git commit -m "feat(server): sign-in with Better Auth (Apple id token, bearer sessions)"
```

- [ ] **Step 7: The review fix (added after review): only the auth routes the app uses, and a nonce on Apple sign-in**

The review found two gaps, both confirmed in Better Auth's source:
- `verify-id-token.mjs` checks an id token's nonce only when the client sends one, so a stolen Apple token could be replayed without it.
- `sign-in/social` without an `idToken` starts the web redirect flow, which the app never uses.

`server/src/auth/routes.ts` (`authHandler`) closes both:
- It answers 404 for every Better Auth route except five: `POST sign-in/social`, `sign-up/email`, `sign-in/email`, `sign-out` and `GET get-session`.
- It answers 400 for a `sign-in/social` without both `idToken.token` and a non-empty `idToken.nonce`.

`index.ts` mounts `authHandler` on `/api/auth/*`. Three tests cover it in `auth.test.ts`: the nonce left out, no id token, and routes the app doesn't use. With them: `Tests  14 passed (14)`.

Commit: `fix(server): only the auth routes the app uses, and Apple sign-in needs its nonce`.

### Task 3: The D1 schema and seeds

**Files:**
- Create: `server/migrations/0002_app_schema.sql`, `server/migrations/0003_seed_exercises.sql` (generated),
  `server/migrations/0004_seed_equipment.sql` (generated)
- Modify: `scripts/gen-exercise-seed.mjs`, `scripts/gen-equipment-seed.mjs`, `scripts/gen-equipment-seed.test.mjs`
- Test: `server/test/schema.test.ts`, `scripts/gen-equipment-seed.test.mjs`

- [ ] **Step 1: Write the failing tests**

`server/test/schema.test.ts`:

```ts
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { signUp } from './helpers.ts'

const T = '2026-11-07T10:00:00.000000Z'

async function count(sql: string, ...bindings: unknown[]): Promise<number> {
  return (await env.DB.prepare(sql).bind(...bindings).first<{ n: number }>())!.n
}

describe('the D1 schema', () => {
  it('holds the exercise library and the equipment catalogue', async () => {
    expect(await count('SELECT count(*) AS n FROM exercises')).toBe(1324)
    expect(await count('SELECT count(*) AS n FROM equipment_kinds')).toBe(46)
    expect(await count('SELECT count(*) AS n FROM equipment_items WHERE brand IS NULL AND model IS NULL')).toBe(46)
    expect(await count('SELECT count(*) AS n FROM exercise_requirements')).toBe(1107)
  })

  it("keeps the library's lists as JSON arrays", async () => {
    const bad = await count("SELECT count(*) AS n FROM exercises WHERE json_type(sm) <> 'array' OR json_type(st) <> 'array'")
    expect(bad).toBe(0)
  })

  it('enforces foreign keys', async () => {
    expect(await env.DB.prepare('PRAGMA foreign_keys').first()).toEqual({ foreign_keys: 1 })
  })

  it('refuses a timestamp that is not in the stored form', async () => {
    const { userId } = await signUp()
    const insert = env.DB.prepare('INSERT INTO profiles (user_id, client_updated_at, updated_at) VALUES (?1, ?2, ?3)')
    await expect(insert.bind(userId, '2026-11-07T10:00:00Z', T).run()).rejects.toThrow(/CHECK constraint failed/)
    await expect(insert.bind(userId, T, T).run()).resolves.toBeTruthy()
  })

  it("removes an account's rows with the account", async () => {
    const { userId } = await signUp()
    await env.DB.prepare('INSERT INTO profiles (user_id, client_updated_at, updated_at) VALUES (?1, ?2, ?2)')
      .bind(userId, T).run()
    await env.DB.prepare('DELETE FROM "user" WHERE id = ?1').bind(userId).run()
    expect(await count('SELECT count(*) AS n FROM profiles WHERE user_id = ?1', userId)).toBe(0)
    expect(await count('SELECT count(*) AS n FROM session WHERE userId = ?1', userId)).toBe(0)
  })
})
```

Append to `scripts/gen-equipment-seed.test.mjs`, and add `seedD1` to its import from `./gen-equipment-seed.mjs`:

```js
test('the D1 seed matches the bundled JSON', () => {
  const sql = seedD1(read('equipment-kinds.json').kinds, read('equipment-requirements.json').requirements)
  assert.equal(readFileSync(resolve(root, 'server/migrations/0004_seed_equipment.sql'), 'utf8'), sql)
})

test('D1 statements hold at most 100 rows, and quotes survive', () => {
  const kinds = Array.from({ length: 101 }, (_, i) => ({
    id: `k${i}`, name: i === 0 ? "O'Brien" : `Kind ${i}`, category: 'rack', load: 'none',
  }))
  const sql = seedD1(kinds, { x: [] })
  assert.equal(sql.match(/INSERT INTO equipment_kinds/g).length, 2)
  assert.match(sql, /'O''Brien'/)
  assert.match(sql, /\('x','\[\]','2026-10-30T00:00:00\.000000Z'\)/)
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/schema.test.ts`
Expected: FAIL with `no such table: exercises`.

Run: `node --test scripts/gen-equipment-seed.test.mjs`
Expected: FAIL. `seedD1` is not exported (`SyntaxError: The requested module … does not provide an export named 'seedD1'`).

- [ ] **Step 3: Write the app schema**

Create `server/migrations/0002_app_schema.sql` with exactly this content. It was translated from the final state of each Postgres table, and checked in `sqlite3` with foreign keys on and D1's pattern limit (`.limit like_pattern_length 50`): every seed row applies and `foreign_key_check` is empty. D1 refuses any LIKE or GLOB pattern over 50 bytes (`LIKE or GLOB pattern too complex`), so the timestamp and photo-name checks are split into short `substr(…) GLOB` pieces.

```sql
-- GymRollins app schema for Cloudflare D1 (SQLite), translated from supabase/migrations/*.sql (the final state of
-- every table). Plan 26; design in docs/specs/2026-11-07-cloudflare-backend-design.md.
--
-- Conventions: ids are TEXT (36-char uuid); timestamps are TEXT 'YYYY-MM-DDTHH:MM:SS.ffffffZ' (UTC); dates are TEXT
-- 'YYYY-MM-DD'; booleans are INTEGER 0/1; jsonb / text[] / numeric[] are TEXT holding JSON. No now()/auth.uid()/
-- gen_random_uuid() defaults: the server supplies ids, user ids and timestamps. Regex and function checks that SQLite
-- cannot express are checked in TypeScript instead. Triggers, views and functions became server code (server/src).
-- The Better Auth table "user" (id TEXT PRIMARY KEY) is owned by Better Auth's own migration (0001).

-- Profiles ------------------------------------------------------------------------------------------------------
CREATE TABLE profiles (
  user_id TEXT NOT NULL PRIMARY KEY REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  unit TEXT NOT NULL DEFAULT 'lb' CHECK (unit IN ('kg','lb')),
  rest_sec INTEGER NOT NULL DEFAULT 120 CHECK (rest_sec BETWEEN 0 AND 900),
  warmup_rest_sec INTEGER NOT NULL DEFAULT 60 CHECK (warmup_rest_sec BETWEEN 0 AND 900),
  height_cm REAL CHECK (height_cm BETWEEN 100 AND 250),
  goal_weight_kg REAL CHECK (goal_weight_kg BETWEEN 30 AND 300),
  goal_date TEXT CHECK (goal_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  training_days INTEGER NOT NULL DEFAULT 4 CHECK (training_days BETWEEN 1 AND 7),
  experience TEXT NOT NULL DEFAULT 'intermediate',
  limits TEXT NOT NULL DEFAULT '' CHECK (length(limits) <= 500),
  deload_pct REAL NOT NULL DEFAULT 0.05 CHECK (deload_pct BETWEEN 0 AND 0.5),
  bar_kg REAL NOT NULL DEFAULT 20.411656,
  plates_kg TEXT NOT NULL DEFAULT '[20.411656,15.87573,11.339809,4.535924,2.267962,1.133981]'
    CHECK (json_valid(plates_kg) AND json_type(plates_kg) = 'array'),
  dumbbell_step_kg REAL NOT NULL DEFAULT 1.133981,
  mcp_read_workouts INTEGER NOT NULL DEFAULT 1 CHECK (mcp_read_workouts IN (0,1)),
  mcp_read_body INTEGER NOT NULL DEFAULT 1 CHECK (mcp_read_body IN (0,1)),
  mcp_propose INTEGER NOT NULL DEFAULT 1 CHECK (mcp_propose IN (0,1)),
  mcp_auto_apply INTEGER NOT NULL DEFAULT 0 CHECK (mcp_auto_apply IN (0,1)),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  mcp_read_plan INTEGER NOT NULL DEFAULT 1 CHECK (mcp_read_plan IN (0,1)),
  sex TEXT CHECK (sex IN ('male','female')),
  birth_year INTEGER CHECK (birth_year BETWEEN 1900 AND 2100),
  mcp_read_gyms INTEGER NOT NULL DEFAULT 1 CHECK (mcp_read_gyms IN (0,1)),
  limits_until TEXT CHECK (limits_until GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]')
);

-- Exercise library (global, read-only for users) ------------------------------------------------------------------
CREATE TABLE exercises (
  id TEXT PRIMARY KEY,
  n TEXT NOT NULL, bp TEXT NOT NULL, eq TEXT NOT NULL, tg TEXT NOT NULL,
  mg TEXT,
  sm TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(sm) AND json_type(sm) = 'array'),
  st TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(st) AND json_type(st) = 'array')
);

CREATE TABLE custom_exercises (
  id TEXT PRIMARY KEY CHECK (id GLOB 'custom-*'),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  n TEXT NOT NULL CHECK (length(n) BETWEEN 1 AND 80),
  bp TEXT NOT NULL, eq TEXT NOT NULL, tg TEXT NOT NULL,
  mode TEXT NOT NULL DEFAULT 'reps' CHECK (mode IN ('reps','time','cardio')),
  bilateral INTEGER NOT NULL DEFAULT 0 CHECK (bilateral IN (0,1)),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  deleted_at TEXT CHECK (substr(deleted_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(deleted_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(deleted_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);

-- Plan ----------------------------------------------------------------------------------------------------------
CREATE TABLE routines (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 40),
  emoji TEXT,
  policy TEXT NOT NULL DEFAULT 'double' CHECK (policy IN ('off','linear','greyskull','double','time')),
  position INTEGER NOT NULL DEFAULT 0,
  paused INTEGER NOT NULL DEFAULT 0 CHECK (paused IN (0,1)),
  exercises TEXT NOT NULL DEFAULT '[]'
    CHECK (json_valid(exercises) AND json_type(exercises) = 'array' AND json_array_length(exercises) <= 20),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  deleted_at TEXT CHECK (substr(deleted_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(deleted_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(deleted_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);

CREATE TABLE week_schedule (
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  weekday INTEGER NOT NULL CHECK (weekday BETWEEN 1 AND 7),
  routine_id TEXT REFERENCES routines(id) ON DELETE SET NULL CHECK (length(routine_id) = 36),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  PRIMARY KEY (user_id, weekday)
);

CREATE TABLE muscle_targets (
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  muscle TEXT NOT NULL CHECK (muscle IN (
    'chest','shoulders','traps','upper_back','lats','lower_back','biceps','triceps','forearms','abs',
    'glutes','quads','hamstrings','calves','adductors','abductors')),
  min_sets INTEGER NOT NULL CHECK (min_sets BETWEEN 0 AND 50),
  max_sets INTEGER NOT NULL CHECK (max_sets BETWEEN 0 AND 50),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  PRIMARY KEY (user_id, muscle),
  CONSTRAINT muscle_targets_range CHECK (min_sets <= max_sets)
);

CREATE TABLE exercise_prefs (
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  -- pg: exercise_id ~ '^[A-Za-z0-9_-]{1,80}$' (translated exactly with GLOB)
  exercise_id TEXT NOT NULL CHECK (length(exercise_id) BETWEEN 1 AND 80 AND exercise_id NOT GLOB '*[^A-Za-z0-9_-]*'),
  pref TEXT NOT NULL CHECK (pref IN ('more','normal','less','never')),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  PRIMARY KEY (user_id, exercise_id)
);
-- Pull cursor: rows changed since the last pull, keyset-ordered by (updated_at, exercise_id).
CREATE INDEX exercise_prefs_user_updated ON exercise_prefs (user_id, updated_at, exercise_id);

-- Curated catalogue + gyms (created before workouts, which link to gyms and listings) ------------------------------
CREATE TABLE equipment_kinds (
  -- pg: id ~ '^[a-z0-9-]{1,40}$' (translated exactly with GLOB)
  id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 1 AND 40 AND id NOT GLOB '*[^a-z0-9-]*'),
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 60),
  category TEXT NOT NULL CHECK (category IN ('machine','cable','free-weight','bench','rack','cardio','accessory')),
  load_type TEXT NOT NULL CHECK (load_type IN ('stack','plate-loaded','fixed-set','bodyweight','none')),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);

CREATE TABLE exercise_requirements (
  exercise_id TEXT PRIMARY KEY REFERENCES exercises(id) ON DELETE CASCADE,
  -- All groups are needed, any one kind per group; [] means no equipment.
  groups TEXT NOT NULL CHECK (json_valid(groups) AND json_type(groups) = 'array'),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);

CREATE TABLE app_admins (
  user_id TEXT NOT NULL PRIMARY KEY REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);

CREATE TABLE user_blocks (
  blocker_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(blocker_id) = 36),
  blocked_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(blocked_id) = 36),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  PRIMARY KEY (blocker_id, blocked_id)
);

CREATE TABLE gyms (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  visibility TEXT NOT NULL CHECK (visibility IN ('public','private')),
  owner_id TEXT REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(owner_id) = 36),
  -- clean_text(...): control characters are refused below; the invisible-character rules are checked in TypeScript
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 120 AND name NOT GLOB ('*[' || char(1) || '-' || char(31) || ']*')),
  address TEXT CHECK (address IS NULL OR (length(address) <= 300 AND address NOT GLOB ('*[' || char(1) || '-' || char(31) || ']*'))),
  latitude REAL CHECK (latitude IS NULL OR latitude BETWEEN -90 AND 90),
  longitude REAL CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180),
  -- pg: maps_place_id ~ '^[A-Za-z0-9._:+/=-]{1,200}$' (translated exactly with GLOB)
  maps_place_id TEXT CHECK (maps_place_id IS NULL
    OR (length(maps_place_id) BETWEEN 1 AND 200 AND maps_place_id NOT GLOB '*[^A-Za-z0-9._:+/=-]*')),
  created_by TEXT REFERENCES "user"(id) ON DELETE SET NULL CHECK (length(created_by) = 36),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','flagged','removed')),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  deleted_at TEXT CHECK (substr(deleted_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(deleted_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(deleted_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  CONSTRAINT gyms_private_has_owner CHECK ((visibility = 'private') = (owner_id IS NOT NULL)),
  CONSTRAINT gyms_public_is_a_place CHECK ((visibility = 'public') = (maps_place_id IS NOT NULL))
);
-- A removed gym gives its place back, so one bad gym can't block a real place forever.
CREATE UNIQUE INDEX gyms_maps_place ON gyms (maps_place_id) WHERE visibility = 'public' AND status <> 'removed';
CREATE INDEX gyms_owner_updated ON gyms (owner_id, updated_at, id) WHERE owner_id IS NOT NULL;
CREATE INDEX gyms_created_by ON gyms (created_by, created_at) WHERE created_by IS NOT NULL;

CREATE TABLE equipment_items (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  kind_id TEXT NOT NULL REFERENCES equipment_kinds(id),
  brand TEXT CHECK (brand IS NULL OR (length(brand) BETWEEN 1 AND 60 AND brand NOT GLOB ('*[' || char(1) || '-' || char(31) || ']*'))),
  model TEXT CHECK (model IS NULL OR (length(model) BETWEEN 1 AND 80 AND model NOT GLOB ('*[' || char(1) || '-' || char(31) || ']*'))),
  created_by TEXT REFERENCES "user"(id) ON DELETE SET NULL CHECK (length(created_by) = 36),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','flagged','removed')),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);
CREATE UNIQUE INDEX equipment_items_identity
  ON equipment_items (kind_id, lower(coalesce(brand, '')), lower(coalesce(model, '')));
CREATE INDEX equipment_items_created_by ON equipment_items (created_by) WHERE created_by IS NOT NULL;

CREATE TABLE gym_equipment (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  gym_id TEXT NOT NULL REFERENCES gyms(id) ON DELETE CASCADE CHECK (length(gym_id) = 36),
  item_id TEXT NOT NULL REFERENCES equipment_items(id) CHECK (length(item_id) = 36),
  visibility TEXT NOT NULL CHECK (visibility IN ('public','private')),
  owner_id TEXT REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(owner_id) = 36),
  -- A bare random name: a folder per user would give every reader the uploader's id.
  -- pg: photo_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$' (exact, as GLOB)
  photo_path TEXT CHECK (photo_path IS NULL OR length(photo_path) = 36+4 AND substr(photo_path,1,4) GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f]' AND substr(photo_path,5,4) GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f]' AND substr(photo_path,10,4) GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f]' AND substr(photo_path,15,4) GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f]' AND substr(photo_path,20,4) GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f]' AND substr(photo_path,25,6) GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]' AND substr(photo_path,31,6) GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]' AND substr(photo_path,9,1)||substr(photo_path,14,1)||substr(photo_path,19,1)||substr(photo_path,24,1)||substr(photo_path,37) = '----.jpg'),
  -- pg: gym_private.valid_loads(loads). Only the structural part is kept: an object, a known type, compact JSON.
  -- Keys, number ranges and the 24-char number form are validated in TypeScript.
  loads TEXT NOT NULL DEFAULT '{"type":"none"}'
    CHECK (json_valid(loads) AND json_type(loads) = 'object' AND length(loads) <= 2048
           AND json_extract(loads, '$.type') IN ('none','plates','stack','fixed')),
  quantity INTEGER NOT NULL DEFAULT 1 CHECK (quantity BETWEEN 1 AND 50),
  notes TEXT CHECK (notes IS NULL OR (length(notes) <= 280 AND notes NOT GLOB ('*[' || char(1) || '-' || char(9) || char(11) || char(12) || char(14) || '-' || char(31) || ']*'))),
  -- A private listing points at its kind's generic item and keeps any brand and model here, so private text never
  -- enters the shared catalogue.
  private_brand TEXT CHECK (private_brand IS NULL OR (length(private_brand) BETWEEN 1 AND 60 AND private_brand NOT GLOB ('*[' || char(1) || '-' || char(31) || ']*'))),
  private_model TEXT CHECK (private_model IS NULL OR (length(private_model) BETWEEN 1 AND 80 AND private_model NOT GLOB ('*[' || char(1) || '-' || char(31) || ']*'))),
  added_by TEXT REFERENCES "user"(id) ON DELETE SET NULL CHECK (length(added_by) = 36),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','flagged','removed')),
  confirm_count INTEGER NOT NULL DEFAULT 0,
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  deleted_at TEXT CHECK (substr(deleted_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(deleted_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(deleted_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  CONSTRAINT gym_equipment_private_has_owner CHECK ((visibility = 'private') = (owner_id IS NOT NULL)),
  CONSTRAINT gym_equipment_private_text
    CHECK (visibility = 'private' OR (private_brand IS NULL AND private_model IS NULL))
);
CREATE INDEX gym_equipment_gym ON gym_equipment (gym_id, status);
-- One photo backs one listing, so a name can't be shared by two.
CREATE UNIQUE INDEX gym_equipment_photo ON gym_equipment (photo_path) WHERE photo_path IS NOT NULL;
CREATE INDEX gym_equipment_item ON gym_equipment (item_id);
CREATE INDEX gym_equipment_owner_updated ON gym_equipment (owner_id, updated_at, id) WHERE owner_id IS NOT NULL;
CREATE INDEX gym_equipment_added_by ON gym_equipment (added_by, created_at) WHERE added_by IS NOT NULL;

CREATE TABLE equipment_confirmations (
  listing_id TEXT NOT NULL REFERENCES gym_equipment(id) ON DELETE CASCADE CHECK (length(listing_id) = 36),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  PRIMARY KEY (listing_id, user_id)
);
CREATE INDEX equipment_confirmations_user ON equipment_confirmations (user_id, created_at);

CREATE TABLE reports (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  target_type TEXT NOT NULL CHECK (target_type IN ('gym','item','listing')),
  target_id TEXT NOT NULL CHECK (length(target_id) = 36),
  -- A report outlives its reporter, so deleting three throwaway accounts can't clear a flag's history.
  reporter_id TEXT REFERENCES "user"(id) ON DELETE SET NULL CHECK (length(reporter_id) = 36),
  reason TEXT NOT NULL CHECK (reason IN ('wrong-info','not-here-anymore','duplicate','inappropriate-photo',
                                         'person-in-photo','spam','other')),
  note TEXT CHECK (note IS NULL OR (length(note) <= 280 AND note NOT GLOB ('*[' || char(1) || '-' || char(9) || char(11) || char(12) || char(14) || '-' || char(31) || ']*'))),
  resolved_at TEXT CHECK (substr(resolved_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(resolved_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(resolved_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  UNIQUE (target_type, target_id, reporter_id)
);

-- gym_private.unblocks in Postgres. Logs each "unblock all" so it can be rate limited (3 a day).
CREATE TABLE gym_unblocks (
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);
CREATE INDEX gym_unblocks_user ON gym_unblocks (user_id, created_at);

-- Workouts (relational children for SQL history queries) ---------------------------------------------------------
CREATE TABLE workouts (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  started_at TEXT NOT NULL CHECK (substr(started_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(started_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(started_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  ended_at TEXT CHECK (substr(ended_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(ended_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(ended_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  paused_sec REAL NOT NULL DEFAULT 0 CHECK (paused_sec >= 0),
  routine_id TEXT CHECK (length(routine_id) = 36),
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
  source TEXT NOT NULL DEFAULT 'app' CHECK (source IN ('app','import')),
  note TEXT,
  vol_kg REAL NOT NULL DEFAULT 0,
  records TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(records)),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  deleted_at TEXT CHECK (substr(deleted_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(deleted_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(deleted_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  gym_id TEXT REFERENCES gyms(id) ON DELETE SET NULL CHECK (length(gym_id) = 36),
  -- Set by each save (server/src/sync/workouts.ts): the save writes its entries and sets only while the row is still
  -- its own, so two phones saving at once can't mix their entries. Never sent to the app.
  write_id TEXT,
  CONSTRAINT workouts_vol_kg_nonnegative CHECK (vol_kg >= 0)
);
CREATE INDEX workouts_user_started ON workouts (user_id, started_at DESC);
CREATE INDEX workouts_gym ON workouts (gym_id) WHERE gym_id IS NOT NULL;

CREATE TABLE workout_entries (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  workout_id TEXT NOT NULL REFERENCES workouts(id) ON DELETE CASCADE CHECK (length(workout_id) = 36),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  exercise_id TEXT NOT NULL,
  position INTEGER NOT NULL,
  note TEXT,
  superset_group TEXT,
  gym_equipment_id TEXT REFERENCES gym_equipment(id) ON DELETE SET NULL CHECK (length(gym_equipment_id) = 36)
);
CREATE INDEX workout_entries_user_exercise ON workout_entries (user_id, exercise_id);
CREATE INDEX workout_entries_workout ON workout_entries (workout_id);

CREATE TABLE workout_sets (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  entry_id TEXT NOT NULL REFERENCES workout_entries(id) ON DELETE CASCADE CHECK (length(entry_id) = 36),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  position INTEGER NOT NULL,
  w_kg REAL NOT NULL CHECK (w_kg BETWEEN 0 AND 1000),
  r INTEGER NOT NULL CHECK (r BETWEEN 0 AND 1000),
  sec INTEGER CHECK (sec BETWEEN 0 AND 86400),
  min REAL, dist_m REAL,
  done INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0,1)),
  warmup INTEGER NOT NULL DEFAULT 0 CHECK (warmup IN (0,1)),
  rir REAL, rpe REAL,
  multiplier REAL NOT NULL DEFAULT 1 CHECK (multiplier BETWEEN 0 AND 10),
  completed_at TEXT CHECK (substr(completed_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(completed_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(completed_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  CONSTRAINT workout_sets_min_range CHECK (min BETWEEN 0 AND 1440),
  CONSTRAINT workout_sets_dist_m_range CHECK (dist_m BETWEEN 0 AND 1000000)
);
CREATE INDEX workout_sets_entry ON workout_sets (entry_id);

-- Body ----------------------------------------------------------------------------------------------------------
CREATE TABLE bodyweight (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  measured_at TEXT NOT NULL CHECK (substr(measured_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(measured_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(measured_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  w_kg REAL NOT NULL CHECK (w_kg BETWEEN 30 AND 300),
  bf_pct REAL CHECK (bf_pct BETWEEN 3 AND 60),
  t TEXT,
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  deleted_at TEXT CHECK (substr(deleted_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(deleted_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(deleted_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  source TEXT CHECK (source IS NULL OR source IN ('apple_health')),
  health_sample_id TEXT CHECK (length(health_sample_id) = 36),
  health_fat_sample_id TEXT CHECK (length(health_fat_sample_id) = 36)
);

-- Proposals from Claude -------------------------------------------------------------------------------------------
CREATE TABLE proposals (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  source TEXT NOT NULL DEFAULT 'claude',
  summary TEXT NOT NULL CHECK (length(summary) BETWEEN 1 AND 500),
  changes TEXT NOT NULL
    CHECK (json_valid(changes) AND json_type(changes) = 'array' AND json_array_length(changes) BETWEEN 1 AND 25),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','applied','dismissed','partial')),
  applied_change_ids TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(applied_change_ids)),
  resolved_at TEXT CHECK (substr(resolved_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(resolved_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(resolved_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);

-- MCP audit + rate limit ------------------------------------------------------------------------------------------
CREATE TABLE mcp_audit (
  id INTEGER PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  client_id TEXT,
  tool TEXT NOT NULL,
  ok INTEGER NOT NULL CHECK (ok IN (0,1)),
  args_digest TEXT,
  at TEXT NOT NULL CHECK (substr(at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);
CREATE INDEX mcp_audit_user_at ON mcp_audit (user_id, at DESC);

CREATE TABLE mcp_calls (
  id INTEGER PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  at TEXT NOT NULL CHECK (substr(at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);
CREATE INDEX mcp_calls_user_at ON mcp_calls (user_id, at DESC);

-- R2 object ownership (replaces storage.objects.owner_id for the gym photo buckets) ---------------------------------
CREATE TABLE photo_objects (
  bucket TEXT NOT NULL CHECK (bucket IN ('gym-photos','gym-photos-private')),
  name TEXT NOT NULL,
  owner_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(owner_id) = 36),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  PRIMARY KEY (bucket, name)
);
CREATE INDEX photo_objects_owner_created ON photo_objects (owner_id, created_at);
```

- [ ] **Step 4: Teach the seed generators D1**

Replace `scripts/gen-exercise-seed.mjs` with:

```js
#!/usr/bin/env node
// exercises.json (bundled in the app) -> the exercise library seeds, so the MCP server can search the same library:
// the Postgres migration and the D1 one (server/migrations). `--check` fails when either differs from the JSON.
import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const postgresOutput = resolve(root, 'supabase/migrations/20260926000002_exercises_seed.sql')
const d1Output = resolve(root, 'server/migrations/0003_seed_exercises.sql')
const credit = 'Exercise names/instructions: hasaneyldrm/exercises-dataset (MIT).'
const rows = JSON.parse(readFileSync(resolve(root, 'ios/GymRollins/Resources/exercises.json'), 'utf8'))
const q = s => s == null ? 'null' : `'${String(s).replaceAll("'", "''")}'`
const arr = a => `array[${(a ?? []).map(q).join(',')}]::text[]`

function postgresSql() {
  const values = rows.map(e => `(${q(e.id)},${q(e.n)},${q(e.bp)},${q(e.eq)},${q(e.tg)},${q(e.mg)},${arr(e.sm)},${arr(e.st)})`)
  return `-- Generated by scripts/gen-exercise-seed.mjs. ${credit}\n` +
    `insert into public.exercises (id,n,bp,eq,tg,mg,sm,st) values\n${values.join(',\n')}\non conflict (id) do nothing;\n`
}

/** D1 keeps text[] as JSON text, and each statement under ~100 KB, so rows go in groups of 100. */
function d1Sql() {
  const json = a => q(JSON.stringify(a ?? []))
  const values = rows.map(e => `(${q(e.id)},${q(e.n)},${q(e.bp)},${q(e.eq)},${q(e.tg)},${q(e.mg)},${json(e.sm)},${json(e.st)})`)
  const statements = []
  for (let i = 0; i < values.length; i += 100) {
    statements.push(`INSERT OR IGNORE INTO exercises (id,n,bp,eq,tg,mg,sm,st) VALUES\n${values.slice(i, i + 100).join(',\n')};`)
  }
  return `-- Generated by scripts/gen-exercise-seed.mjs. ${credit}\n${statements.join('\n')}\n`
}

const outputs = [[postgresOutput, postgresSql()], [d1Output, d1Sql()]]
if (process.argv.includes('--check')) {
  const stale = outputs.filter(([path, sql]) => readFileSync(path, 'utf8') !== sql).map(([path]) => path)
  if (stale.length > 0) {
    console.error(`Out of date: ${stale.join(', ')}. Run scripts/gen-exercise-seed.mjs`)
    process.exit(1)
  }
  console.log('Exercise seeds match the bundled JSON')
} else {
  for (const [path, sql] of outputs) writeFileSync(path, sql)
  console.log(`Seeded ${rows.length} exercises`)
}
```

In `scripts/gen-equipment-seed.mjs`:

1. Replace the header comment and the `output` constant:

```js
#!/usr/bin/env node
// equipment-kinds.json and equipment-requirements.json (bundled in the app) -> the equipment seeds, plus one generic
// catalogue item per kind: the Postgres migration and the D1 one (server/migrations). `--check` fails when either
// differs from what the JSON generates (the drift test).
```

```js
const postgresOutput = resolve(root, 'supabase/migrations/20261030000004_equipment_seed.sql')
const d1Output = resolve(root, 'server/migrations/0004_seed_equipment.sql')
```

2. Below `seedSql`, add:

```js
/** D1 columns have no now() default, so the D1 seed stamps one fixed time. */
export const d1SeedTimestamp = '2026-10-30T00:00:00.000000Z'

/** The same rows for D1, at most 100 per statement. */
export function seedD1(kinds, requirements) {
  const ts = q(d1SeedTimestamp)
  const kindRows = kinds.map((k) => `(${q(k.id)},${q(k.name)},${q(k.category)},${q(k.load)},${ts})`)
  const itemRows = kinds.map((k) => `(${q(stableUUID(genericItemNamespace, k.id))},${q(k.id)},${ts},${ts})`)
  const requirementRows = Object.keys(requirements).sort()
    .map((id) => `(${q(id)},${q(JSON.stringify(requirements[id]))},${ts})`)
  return [
    '-- Generated by scripts/gen-equipment-seed.mjs from the JSON bundled in the app. Do not edit by hand.',
    ...chunked('equipment_kinds', 'id,name,category,load_type,created_at', kindRows),
    ...chunked('equipment_items', 'id,kind_id,created_at,updated_at', itemRows),
    ...chunked('exercise_requirements', 'exercise_id,groups,created_at', requirementRows),
    '',
  ].join('\n')
}

function chunked(table, columns, rows) {
  const statements = []
  for (let i = 0; i < rows.length; i += 100) {
    statements.push(`INSERT INTO ${table} (${columns}) VALUES\n${rows.slice(i, i + 100).join(',\n')};`)
  }
  return statements
}
```

3. Replace `generate()` and the command-line block with:

```js
function generate() {
  const read = (name) => JSON.parse(readFileSync(resolve(root, 'ios/GymRollins/Resources', name), 'utf8'))
  const kinds = read('equipment-kinds.json').kinds
  const requirements = read('equipment-requirements.json').requirements
  return [[postgresOutput, seedSql(kinds, requirements)], [d1Output, seedD1(kinds, requirements)]]
}

if (process.argv[1] === import.meta.filename) {
  const outputs = generate()
  if (process.argv.includes('--check')) {
    const stale = outputs.filter(([path, sql]) => readFileSync(path, 'utf8') !== sql).map(([path]) => path)
    if (stale.length > 0) {
      console.error(`The equipment seed differs from the bundled JSON (${stale.join(', ')}): run scripts/gen-equipment-seed.mjs`)
      process.exit(1)
    }
    console.log('Equipment seeds match the bundled JSON')
  } else {
    for (const [path, sql] of outputs) {
      writeFileSync(path, sql)
      console.log(`Wrote ${path}`)
    }
  }
}
```

4. In `scripts/gen-equipment-seed.test.mjs`, the first test reads `supabase/migrations/20261030000004_equipment_seed.sql`. That path stays as it is.

- [ ] **Step 5: Generate the seeds**

Run:

```bash
node scripts/gen-exercise-seed.mjs && node scripts/gen-equipment-seed.mjs && git status --short supabase server/migrations
```

Expected:
- `Seeded 1324 exercises` and two `Wrote …` lines.
- `git status` lists only the two new `server/migrations/000[34]_*.sql` files. The regenerated Postgres seeds must be byte-identical, so `supabase/` shows nothing.

- [ ] **Step 6: Run the tests**

Run: `node --test scripts/gen-equipment-seed.test.mjs && node scripts/gen-exercise-seed.mjs --check && node scripts/gen-equipment-seed.mjs --check`
Expected: `# pass 5`, `# fail 0`, `Exercise seeds match the bundled JSON`, `Equipment seeds match the bundled JSON`.

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  4 passed (4)`, `Tests  24 passed (24)`.

- [ ] **Step 7: Commit**

```bash
git add server/migrations scripts/gen-exercise-seed.mjs scripts/gen-equipment-seed.mjs scripts/gen-equipment-seed.test.mjs server/test/schema.test.ts
git commit -m "feat(server): D1 schema and seeds"
```

- [ ] **Step 8: Found while building, D1's 50-byte pattern limit**

The first schema used one GLOB per timestamp check (about 100 bytes) and per photo name (about 190 bytes). It applied in `sqlite3` but not in workerd's D1. The checks are now split into pieces of at most 48 bytes.

`schema.test.ts` adds:
- a scan of every migration for a LIKE or GLOB literal over 50 bytes,
- the photo-name check: one accepted, five refused,
- three malformed timestamps.

With them: `Tests  24 passed (24)`.

Commit: `fix(server): D1's 50-byte GLOB limit in the photo name check, with tests`.

### Task 4: Timestamps and column values

**Files:**
- Create: `server/src/sync/time.ts`, `server/src/sync/columns.ts`
- Test: `server/test/time.test.ts`, `server/test/columns.test.ts`

- [ ] **Step 1: Write the failing tests**

`server/test/time.test.ts`:

```ts
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { laterStamp, normalizeTimestamp, NOW_SQL } from '../src/sync/time.ts'

describe('normalizeTimestamp', () => {
  it.each([
    ['2026-11-07T10:00:00.123456Z', '2026-11-07T10:00:00.123456Z'],
    ['2026-11-07T10:00:00Z', '2026-11-07T10:00:00.000000Z'],
    ['2026-11-07T10:00:00', '2026-11-07T10:00:00.000000Z'],
    ['2026-11-07 10:00:00.5z', '2026-11-07T10:00:00.500000Z'],
    ['2026-11-07T10:00:00.123456789+00:00', '2026-11-07T10:00:00.123456Z'],
    ['2026-11-07T10:00:00+0200', '2026-11-07T08:00:00.000000Z'],
    ['2026-11-07T00:30:00-01', '2026-11-07T01:30:00.000000Z'],
    ['2026-01-01T00:00:00.000001-00:30', '2026-01-01T00:30:00.000001Z'],
    ['1969-12-31T23:59:59.999999Z', '1969-12-31T23:59:59.999999Z'],
    ['0050-01-01T00:00:00Z', '0050-01-01T00:00:00.000000Z'],
    ['0001-01-01T00:00:00+01', '0000-12-31T23:00:00.000000Z'],
  ])('reads %s as %s', (raw, stored) => {
    expect(normalizeTimestamp(raw)).toBe(stored)
  })

  it.each(['2026-11-07', 'yesterday', '2026-13-01T00:00:00Z', '2026-11-07T24:00:00Z', '2026-11-07T10:60:00Z', ''])(
    'refuses %j',
    (raw) => {
      expect(normalizeTimestamp(raw)).toBeNull()
    },
  )
})

describe('NOW_SQL', () => {
  it("is the database's clock, in the stored form", async () => {
    const { now } = (await env.DB.prepare(`SELECT ${NOW_SQL} AS now`).first<{ now: string }>())!
    expect(now).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}000Z$/)
    expect(Math.abs(Date.parse(now) - Date.now())).toBeLessThan(5_000)
  })
})

describe('laterStamp', () => {
  const later = async (stored: string, now: string) =>
    (await env.DB.prepare(`SELECT ${laterStamp('?1', '?2')} AS s`).bind(stored, now).first<{ s: string }>())!.s

  it('takes the clock when it has moved past the stored stamp', async () => {
    expect(await later('2026-11-07T10:00:00.123000Z', '2026-11-07T10:00:00.124000Z')).toBe('2026-11-07T10:00:00.124000Z')
  })

  it('goes a microsecond past the stored stamp when the clock has not, so every write changes it', async () => {
    expect(await later('2026-11-07T10:00:00.123000Z', '2026-11-07T10:00:00.123000Z')).toBe('2026-11-07T10:00:00.123001Z')
    expect(await later('2026-11-07T10:00:00.123999Z', '2026-11-07T10:00:00.123000Z')).toBe('2026-11-07T10:00:00.124000Z')
  })
})
```

`server/test/columns.test.ts`:

```ts
import { describe, expect, it } from 'vitest'
import { type Column, RowError, storedRow, storedValue, wireRow, wireValue } from '../src/sync/columns.ts'

const col = (kind: Column['kind'], extra: Partial<Column> = {}): Column => ({ name: 'x', kind, ...extra })
const stored = (column: Column, raw: unknown) => storedValue(column, raw, 'rows[0]')

describe('storedValue', () => {
  it('lowercases UUIDs and refuses anything else', () => {
    expect(stored(col('uuid'), 'A1B2C3D4-0000-4000-8000-00000000000F')).toBe('a1b2c3d4-0000-4000-8000-00000000000f')
    expect(() => stored(col('uuid'), 'not-a-uuid')).toThrow(RowError)
  })

  it('stores booleans as 1 and 0', () => {
    expect(stored(col('bool'), true)).toBe(1)
    expect(stored(col('bool'), false)).toBe(0)
    expect(() => stored(col('bool'), 1)).toThrow('rows[0].x is not a valid bool')
  })

  it('keeps integers whole and reals finite', () => {
    expect(stored(col('int'), 3)).toBe(3)
    expect(() => stored(col('int'), 2.5)).toThrow(RowError)
    expect(() => stored(col('int'), '3')).toThrow(RowError)
    expect(() => stored(col('int'), 2 ** 60)).toThrow(RowError)
    expect(stored(col('real'), 2.5)).toBe(2.5)
    expect(() => stored(col('real'), '2.5')).toThrow(RowError)
  })

  it('stores JSON as text', () => {
    expect(stored(col('json'), [1, { a: 2 }])).toBe('[1,{"a":2}]')
    expect(() => stored(col('json'), 'text')).toThrow(RowError)
  })

  it('normalises timestamps, and takes dates as real YYYY-MM-DD days only', () => {
    expect(stored(col('ts'), '2026-11-07T10:00:00Z')).toBe('2026-11-07T10:00:00.000000Z')
    expect(() => stored(col('ts'), '2026-11-07')).toThrow('rows[0].x is not a valid ts')
    expect(stored(col('date'), '2026-12-31')).toBe('2026-12-31')
    expect(() => stored(col('date'), '2026-12-31T00:00:00Z')).toThrow(RowError)
    expect(() => stored(col('date'), '2026-13-45')).toThrow(RowError)
    expect(() => stored(col('date'), '2026-02-30')).toThrow(RowError)
  })

  it('treats a missing or null value by the column', () => {
    expect(stored(col('real', { nullable: true }), null)).toBeNull()
    expect(stored(col('real', { nullable: true }), undefined)).toBeNull()
    expect(stored(col('real', { fallback: 0 }), undefined)).toBe(0)
    expect(stored(col('json', { fallback: [] }), null)).toBe('[]')
    expect(stored(col('bool', { fallback: false }), null)).toBe(0)
    expect(() => stored(col('real'), null)).toThrow('rows[0].x is required')
  })
})

describe('storedRow', () => {
  it('names the row and the column that failed', () => {
    expect(() => storedRow([col('int')], { x: 'no' }, 'rows[3]')).toThrow('rows[3].x is not a valid int')
    expect(() => storedRow([col('int')], 'no', 'rows[3]')).toThrow('rows[3] is not an object')
    expect(() => storedRow([col('int')], [1], 'rows[3]')).toThrow('rows[3] is not an object')
  })

  it("ignores keys it doesn't know, such as a user_id the app never sends", () => {
    expect(storedRow([col('int')], { x: 1, updated_at: 'z', user_id: 'someone' }, 'rows[0]')).toEqual({ x: 1 })
  })
})

describe('wireValue and wireRow', () => {
  it('answer booleans and JSON as the app decodes them', () => {
    expect(wireValue(col('bool'), 1)).toBe(true)
    expect(wireValue(col('bool'), 0)).toBe(false)
    expect(wireValue(col('json'), '[1,2]')).toEqual([1, 2])
    expect(wireValue(col('real'), null)).toBeNull()
    expect(wireValue(col('ts'), '2026-11-07T10:00:00.000000Z')).toBe('2026-11-07T10:00:00.000000Z')
  })

  it('pass other keys through', () => {
    expect(wireRow([col('bool')], { x: 1, updated_at: 't' })).toEqual({ x: true, updated_at: 't' })
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/time.test.ts test/columns.test.ts`
Expected: FAIL with `Failed to load url ../src/sync/time.ts` and `../src/sync/columns.ts`.

- [ ] **Step 3: Write `server/src/sync/time.ts`**

```ts
// Timestamps are stored as text in one form, YYYY-MM-DDTHH:MM:SS.ffffffZ (UTC, six digits), so text order is time order
// and last-write-wins compares like with like. The app writes that form too (SyncDate.format) and reads any form below.

const PATTERN = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|z|[+-]\d{2}(?::?\d{2})?)?$/

/**
 * The server's clock, in the stored form, read by SQLite in the statement that writes. D1 runs writes one at a time, so
 * a later write never gets an earlier stamp; the Worker's own clock is frozen during a request, so it isn't used.
 */
export const NOW_SQL = `(strftime('%Y-%m-%dT%H:%M:%f', 'now') || '000Z')`

/**
 * The updated_at an update stores: `now`, or a microsecond past `stored` when the millisecond clock hasn't moved past
 * it. Every accepted write then changes a row's stamp, which the app's conflict check (exact equality with the version
 * it last saw) and its pull cursor (`updated_at > cursor`) rely on. Both arguments are SQL expressions.
 */
export const laterStamp = (stored: string, now: string) =>
  `(CASE WHEN ${now} > ${stored} THEN ${now} ` +
  `ELSE substr(${stored}, 1, 20) || printf('%06d', CAST(substr(${stored}, 21, 6) AS INTEGER) + 1) || 'Z' END)`

/**
 * A timestamp from the app in the stored form, or null. Accepts what the app's SyncDate.parse accepts: 0 or more
 * fractional digits (truncated to six), `T` or a space, and `Z`, `z`, `±hh`, `±hhmm`, `±hh:mm` or no offset (UTC).
 */
export function normalizeTimestamp(raw: string): string | null {
  const m = PATTERN.exec(raw)
  if (!m) return null
  const [year, month, day, hour, minute, second] = m.slice(1, 7).map(Number)
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60) return null
  const offset = offsetSeconds(m[8])
  if (offset === null) return null
  const micros = BigInt(`${m[7] ?? ''}000000`.slice(0, 6))
  const civil = new Date(0)
  civil.setUTCFullYear(year, month - 1, day)
  civil.setUTCHours(hour, minute, second, 0)
  const seconds = BigInt(civil.getTime() / 1000) - BigInt(offset)
  return format(seconds * 1_000_000n + micros)
}

function offsetSeconds(raw: string | undefined): number | null {
  if (raw === undefined || raw === 'Z' || raw === 'z') return 0
  const sign = raw.startsWith('-') ? -1 : 1
  const digits = raw.slice(1).replace(':', '')
  const hours = Number(digits.slice(0, 2))
  const minutes = digits.length > 2 ? Number(digits.slice(2)) : 0
  if (!Number.isInteger(hours) || !Number.isInteger(minutes)) return null
  return sign * (hours * 3_600 + minutes * 60)
}

function format(totalMicros: bigint): string | null {
  let seconds = totalMicros / 1_000_000n
  let micros = totalMicros % 1_000_000n
  if (micros < 0n) {
    micros += 1_000_000n
    seconds -= 1n
  }
  const iso = new Date(Number(seconds) * 1000).toISOString()
  if (!/^\d{4}-/.test(iso)) return null
  return `${iso.slice(0, 19)}.${micros.toString().padStart(6, '0')}Z`
}
```

- [ ] **Step 4: Write `server/src/sync/columns.ts`**

```ts
import { ApiError } from '../http/errors.ts'
import { normalizeTimestamp } from './time.ts'

/** How a column travels between the app's JSON and D1 (spec section 3, "Type mapping"). */
export type Kind = 'text' | 'int' | 'real' | 'bool' | 'json' | 'ts' | 'date' | 'uuid'

export interface Column {
  readonly name: string
  readonly kind: Kind
  /** Missing or null is stored as NULL. */
  readonly nullable?: boolean
  /** Missing or null is stored as this, like upsert_workout's coalesce(…, default). */
  readonly fallback?: unknown
}

/** A row the server won't store: 422 row_rejected, which the app records as a refused row (as with SQLSTATE 22/23). */
export class RowError extends ApiError {
  constructor(message: string) {
    super(422, 'row_rejected', message)
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const DAY = /^\d{4}-\d{2}-\d{2}$/

/** YYYY-MM-DD and a real day, as Postgres's `date` type required (the D1 CHECK only sees the shape). */
function isCalendarDay(raw: string): boolean {
  if (!DAY.test(raw)) return false
  const day = new Date(`${raw}T00:00:00Z`)
  return !Number.isNaN(day.getTime()) && day.toISOString().slice(0, 10) === raw
}

/** `raw`, a value from the app's JSON, as D1 stores it; throws RowError naming `label.column` when it doesn't fit. */
export function storedValue(column: Column, raw: unknown, label: string): unknown {
  if (raw === undefined || raw === null) {
    if (column.fallback !== undefined) return storedValue({ ...column, fallback: undefined }, column.fallback, label)
    if (column.nullable) return null
    throw new RowError(`${label}.${column.name} is required`)
  }
  const value = convert(column.kind, raw)
  if (value === undefined) throw new RowError(`${label}.${column.name} is not a valid ${column.kind}`)
  return value
}

function convert(kind: Kind, raw: unknown): unknown {
  switch (kind) {
    case 'text':
      return typeof raw === 'string' ? raw : undefined
    case 'int':
      return Number.isSafeInteger(raw) ? raw : undefined
    case 'real':
      return typeof raw === 'number' && Number.isFinite(raw) ? raw : undefined
    case 'bool':
      return typeof raw === 'boolean' ? (raw ? 1 : 0) : undefined
    case 'json':
      return typeof raw === 'object' ? JSON.stringify(raw) : undefined
    case 'ts':
      return typeof raw === 'string' ? (normalizeTimestamp(raw) ?? undefined) : undefined
    case 'date':
      return typeof raw === 'string' && isCalendarDay(raw) ? raw : undefined
    case 'uuid':
      return typeof raw === 'string' && UUID.test(raw) ? raw.toLowerCase() : undefined
  }
}

/** The `columns` of `raw` (an object from the app), stored. Keys it doesn't name, like updated_at, are ignored. */
export function storedRow(columns: readonly Column[], raw: unknown, label: string): Record<string, unknown> {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) throw new RowError(`${label} is not an object`)
  const source = raw as Record<string, unknown>
  return Object.fromEntries(columns.map((c) => [c.name, storedValue(c, source[c.name], label)]))
}

/** A stored value as the app's JSON has it: booleans as true/false, JSON parsed. */
export function wireValue(column: Column, stored: unknown): unknown {
  if (stored === null || stored === undefined) return null
  if (column.kind === 'bool') return stored === 1
  if (column.kind === 'json') return JSON.parse(String(stored))
  return stored
}

/** A stored row as the app's JSON has it. Keys that aren't in `columns` (updated_at, user_id) pass through. */
export function wireRow(columns: readonly Column[], row: Record<string, unknown>): Record<string, unknown> {
  const out = { ...row }
  for (const column of columns) out[column.name] = wireValue(column, row[column.name])
  return out
}
```

- [ ] **Step 5: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  6 passed (6)`, `Tests  54 passed (54)`.

- [ ] **Step 6: Commit**

```bash
git add server/src/sync server/test/time.test.ts server/test/columns.test.ts
git commit -m "feat(server): timestamps and column values for sync"
```

### Task 5: Row sync

The profile, custom exercises, exercise preferences, routines, the week, muscle targets and body weight are each described once. One push and one pull serve all seven.

**Files:**
- Create: `server/src/sync/entities.ts`, `server/src/sync/table-sync.ts`, `server/src/sync/routes.ts`,
  `server/src/auth/session.ts`, `server/src/http/body.ts`, `server/test/samples.ts`
- Modify: `server/src/index.ts`
- Test: `server/test/sync-rows.test.ts`

- [ ] **Step 1: Write the samples and the failing tests**

`server/test/samples.ts`:

```ts
import { ENTITIES } from '../src/sync/entities.ts'

// Rows as the app encodes them (SyncJSON): uppercase UUIDs, six-digit UTC times, explicit nulls. Made-up values only.

export type Row = Record<string, unknown>

export const T0 = '2026-11-07T09:00:00.000000Z'
export const T1 = '2026-11-07T10:00:00.000000Z'
export const T2 = '2026-11-07T11:00:00.000000Z'

export const appUUID = () => crypto.randomUUID().toUpperCase()

export const SAMPLES: Readonly<Record<string, () => Row>> = {
  profile: () => ({
    unit: 'kg', rest_sec: 120, warmup_rest_sec: 60, height_cm: 180, goal_weight_kg: null, goal_date: '2027-06-30',
    training_days: 4, experience: 'intermediate', limits: '', limits_until: null, deload_pct: 0.05, bar_kg: 20,
    plates_kg: [20, 10, 5, 2.5, 1.25], dumbbell_step_kg: 2, mcp_read_workouts: true, mcp_read_body: false,
    mcp_read_plan: true, mcp_read_gyms: true, mcp_propose: true, mcp_auto_apply: false, sex: null, birth_year: null,
    client_updated_at: T1,
  }),
  'custom-exercises': () => ({
    id: `custom-${crypto.randomUUID()}`, n: 'Sled push', bp: 'legs', eq: 'machine', tg: 'quads', mode: 'reps',
    bilateral: true, client_updated_at: T1, deleted_at: null,
  }),
  'exercise-prefs': () => ({ exercise_id: `ex_${crypto.randomUUID().slice(0, 8)}`, pref: 'more', client_updated_at: T1 }),
  routines: () => ({
    id: appUUID(), name: 'Push', emoji: null, policy: 'double', position: 0, paused: false,
    exercises: [{
      id: appUUID(), exercise_id: 'bench_press', position: 0, sets: 3, reps: 8, mode: 'reps', weight_kg: 60,
      weight_set_at: '2026-11-01T09:00:00.000000Z',
    }],
    client_updated_at: T1, deleted_at: null,
  }),
  weekdays: () => ({ weekday: 3, routine_id: null, client_updated_at: T1 }),
  'muscle-targets': () => ({ muscle: 'chest', min_sets: 10, max_sets: 16, client_updated_at: T1 }),
  bodyweight: () => ({
    id: appUUID(), measured_at: '2026-11-07T07:00:00.000000Z', w_kg: 75.5, bf_pct: null, t: '07:00', source: null,
    health_sample_id: null, health_fat_sample_id: null, client_updated_at: T1, deleted_at: null,
  }),
}

/** A change that breaks one of the table's CHECK constraints. */
export const BAD: Readonly<Record<string, Row>> = {
  profile: { rest_sec: 901 },
  'custom-exercises': { mode: 'swim' },
  'exercise-prefs': { pref: 'maybe' },
  routines: { name: '' },
  weekdays: { weekday: 8 },
  'muscle-targets': { min_sets: 20, max_sets: 10 },
  bodyweight: { w_kg: 500 },
}

/** The ack id the app matches for a row. */
export const KEY: Readonly<Record<string, (row: Row, userId: string) => string>> = {
  profile: (_, userId) => userId,
  'custom-exercises': (row) => String(row.id),
  'exercise-prefs': (row) => String(row.exercise_id),
  routines: (row) => String(row.id).toLowerCase(),
  weekdays: (row) => String(row.weekday),
  'muscle-targets': (row) => String(row.muscle),
  bodyweight: (row) => String(row.id).toLowerCase(),
}

/** What a pull answers for a pushed row: its UUID columns lowercased, plus updated_at (and user_id on the profile). */
export function pulled(entity: string, row: Row, updatedAt: string, userId: string): Row {
  const out: Row = { ...row, updated_at: updatedAt }
  for (const column of ENTITIES[entity].columns) {
    if (column.kind === 'uuid' && typeof out[column.name] === 'string') out[column.name] = String(out[column.name]).toLowerCase()
  }
  if (ENTITIES[entity].pullsUserId) out.user_id = userId
  return out
}
```

`server/test/sync-rows.test.ts`:

```ts
import { describe, expect, it } from 'vitest'
import { ENTITIES } from '../src/sync/entities.ts'
import { request, signUp } from './helpers.ts'
import { BAD, KEY, pulled, type Row, SAMPLES, T0, T1, T2 } from './samples.ts'

interface Ack {
  id: string
  updated_at: string
}

const STAMP = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/

const push = (token: string, entity: string, rows: unknown) =>
  request('POST', `/v1/sync/${entity}`, { token, body: { rows } })

async function acks(token: string, entity: string, rows: Row[]): Promise<Ack[]> {
  const res = await push(token, entity, rows)
  expect(res.status).toBe(200)
  return (await res.json<{ acks: Ack[] }>()).acks
}

async function pull(token: string, entity: string, query = ''): Promise<Row[]> {
  const res = await request('GET', `/v1/sync/${entity}${query}`, { token })
  expect(res.status).toBe(200)
  return (await res.json<{ rows: Row[] }>()).rows
}

describe.each(Object.keys(ENTITIES))('%s', (entity) => {
  it('stores a row and answers it back as the app sent it', async () => {
    const { token, userId } = await signUp()
    const row = SAMPLES[entity]()
    const [ack, ...more] = await acks(token, entity, [row])
    expect(more).toEqual([])
    expect(ack.id).toBe(KEY[entity](row, userId))
    expect(ack.updated_at).toMatch(STAMP)
    expect(await pull(token, entity)).toEqual([pulled(entity, row, ack.updated_at, userId)])
  })

  it('takes an equal or newer edit, and skips an older one without an ack', async () => {
    const { token } = await signUp()
    const row = SAMPLES[entity]()
    await acks(token, entity, [{ ...row, client_updated_at: T1 }])
    expect(await acks(token, entity, [{ ...row, client_updated_at: T1 }])).toHaveLength(1)
    expect(await acks(token, entity, [{ ...row, client_updated_at: T2 }])).toHaveLength(1)
    expect(await acks(token, entity, [{ ...row, client_updated_at: T0 }])).toEqual([])
    const [stored] = await pull(token, entity)
    expect(stored.client_updated_at).toBe(T2)
  })

  it('keeps accounts apart', async () => {
    const a = await signUp()
    const b = await signUp()
    const row = SAMPLES[entity]()
    await acks(a.token, entity, [{ ...row, client_updated_at: T1 }])
    expect(await pull(b.token, entity)).toEqual([])
    const res = await push(b.token, entity, [{ ...row, client_updated_at: T2 }])
    if (ENTITIES[entity].conflict.includes('user_id')) {
      expect(res.status).toBe(200)
      expect(await pull(b.token, entity)).toHaveLength(1)
    } else {
      expect(res.status).toBe(403)
      expect(await res.json()).toMatchObject({ error: { code: 'not_allowed' } })
    }
    const [mine] = await pull(a.token, entity)
    expect(mine.client_updated_at).toBe(T1)
  })

  it('refuses a row that breaks a rule, and stores nothing from that push', async () => {
    const { token } = await signUp()
    const bad = { ...SAMPLES[entity](), ...BAD[entity] }
    const res = await push(token, entity, entity === 'profile' ? [bad] : [SAMPLES[entity](), bad])
    expect(res.status).toBe(422)
    const body = await res.json<{ error: { code: string; message: string } }>()
    expect(body.error.code).toBe('row_rejected')
    expect(body.error.message).toMatch(/CHECK constraint failed/)
    expect(await pull(token, entity)).toEqual([])
  })

  it('refuses a value of the wrong type, naming the row and column', async () => {
    const { token } = await signUp()
    const res = await push(token, entity, [SAMPLES[entity](), { ...SAMPLES[entity](), client_updated_at: 'yesterday' }])
    expect(res.status).toBe(422)
    expect(await res.json()).toEqual({
      error: { code: 'row_rejected', message: 'rows[1].client_updated_at is not a valid ts' },
    })
  })
})

describe('pulling', () => {
  it('pages by (updated_at, key) without gaps or repeats', async () => {
    const { token } = await signUp()
    const rows = Array.from({ length: 5 }, () => SAMPLES.routines())
    await acks(token, 'routines', rows)
    const seen: Row[] = []
    let query = '?limit=2'
    for (;;) {
      const page = await pull(token, 'routines', query)
      seen.push(...page)
      if (page.length < 2) break
      const last = page[page.length - 1]
      query = `?limit=2&since=${encodeURIComponent(String(last.updated_at))}&after=${encodeURIComponent(String(last.id))}`
    }
    expect(seen.map((r) => r.id).sort()).toEqual(rows.map((r) => String(r.id).toLowerCase()).sort())
  })

  it('pages the week by weekday number', async () => {
    const { token } = await signUp()
    await acks(token, 'weekdays', [1, 2, 3].map((weekday) => ({ ...SAMPLES.weekdays(), weekday })))
    const first = await pull(token, 'weekdays', '?limit=1')
    expect(first.map((r) => r.weekday)).toEqual([1])
    const since = encodeURIComponent(String(first[0].updated_at))
    expect((await pull(token, 'weekdays', `?limit=5&since=${since}&after=1`)).map((r) => r.weekday)).toEqual([2, 3])
  })

  it('answers only rows changed after `since`', async () => {
    const { token } = await signUp()
    const [ack] = await acks(token, 'routines', [SAMPLES.routines()])
    expect(await pull(token, 'routines', `?since=${encodeURIComponent(ack.updated_at)}`)).toEqual([])
  })

  it('answers as many rows as the limit asks for (the app stops at a short page)', async () => {
    const { token } = await signUp()
    await acks(token, 'routines', Array.from({ length: 3 }, () => SAMPLES.routines()))
    expect(await pull(token, 'routines', '?limit=3')).toHaveLength(3)
  })

  it.each(['?limit=0', '?limit=1001', '?limit=two', '?since=yesterday', '?after=x'])('refuses %s', async (query) => {
    const { token } = await signUp()
    const res = await request('GET', `/v1/sync/routines${query}`, { token })
    expect(res.status).toBe(400)
    expect(await res.json()).toMatchObject({ error: { code: 'bad_request' } })
  })
})

describe('the week', () => {
  it("takes a day with one of your routines, and refuses someone else's", async () => {
    const a = await signUp()
    const b = await signUp()
    const routine = SAMPLES.routines()
    await acks(a.token, 'routines', [routine])
    const [ack] = await acks(a.token, 'weekdays', [{ ...SAMPLES.weekdays(), weekday: 1, routine_id: routine.id }])
    expect(ack.id).toBe('1')
    const res = await push(b.token, 'weekdays', [{ ...SAMPLES.weekdays(), routine_id: routine.id }])
    expect(res.status).toBe(422)
    expect(await res.json()).toMatchObject({ error: { code: 'row_rejected' } })
  })
})

describe('the sync routes', () => {
  it('need a session', async () => {
    for (const res of [await request('GET', '/v1/sync/routines'), await push('not-a-token', 'routines', [])]) {
      expect(res.status).toBe(401)
      expect(await res.json()).toEqual({ error: { code: 'signed_out', message: 'Sign in required.' } })
    }
  })

  it('answer an unknown table with 404', async () => {
    const { token } = await signUp()
    expect((await request('GET', '/v1/sync/nope', { token })).status).toBe(404)
  })

  it('refuse a body that is not JSON, has no rows, or has too many', async () => {
    const { token } = await signUp()
    expect((await request('POST', '/v1/sync/routines', { token, body: 'nope' })).status).toBe(400)
    expect((await request('POST', '/v1/sync/routines', { token, body: {} })).status).toBe(400)
    const many = Array.from({ length: 501 }, () => SAMPLES.routines())
    expect((await push(token, 'routines', many)).status).toBe(400)
  })

  it('answer an empty push with no acks', async () => {
    const { token } = await signUp()
    expect(await acks(token, 'routines', [])).toEqual([])
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/sync-rows.test.ts`
Expected: FAIL with `Failed to load url ../src/sync/entities.ts`.

- [ ] **Step 3: Write the session, the body reader and the tables**

`server/src/auth/session.ts`:

```ts
import type { MiddlewareHandler } from 'hono'
import type { AppEnv } from '../env.ts'
import { ApiError } from '../http/errors.ts'
import { createAuth } from './auth.ts'

/** The app's routes: the user of the Better Auth session in `Authorization: Bearer <token>`, or 401 signed_out. */
export const requireUser: MiddlewareHandler<AppEnv> = async (c, next) => {
  const session = await createAuth(c.env).api.getSession({ headers: c.req.raw.headers })
  if (!session) throw new ApiError(401, 'signed_out', 'Sign in required.')
  c.set('userId', session.user.id)
  await next()
}
```

`server/src/http/body.ts`:

```ts
import type { Context } from 'hono'
import { ApiError } from './errors.ts'

export async function jsonBody(c: Context): Promise<unknown> {
  try {
    return await c.req.json()
  } catch {
    throw new ApiError(400, 'bad_request', 'The body must be JSON.')
  }
}
```

`server/src/sync/entities.ts`:

```ts
import { ApiError } from '../http/errors.ts'
import { type Column, type Kind, RowError } from './columns.ts'

/** One synced table, which the app's SyncTransport pushes and pulls at /v1/sync/<name> (the names below). */
export interface Entity {
  readonly table: string
  /** The ON CONFLICT target: user_id plus the row's key, or a row id alone (then other accounts' ids are refused). */
  readonly conflict: readonly string[]
  /** The column whose value is the ack id. The app matches acks lowercased. */
  readonly ackKey: string
  /** KeysetPager's tiebreak after updated_at, and how `after` is read. */
  readonly tiebreak: { readonly column: string; readonly kind: 'text' | 'int' }
  /** What the app sends and gets back, besides updated_at (and user_id, on the profile). */
  readonly columns: readonly Column[]
  /** When an update applies, besides the owner check. Default: last write wins by the device's edit time. */
  readonly applies?: string
  /** Update expressions in place of `excluded.<column>`. */
  readonly onUpdate?: Readonly<Record<string, string>>
  /** Pulled rows carry user_id: the profile's tiebreak. */
  readonly pullsUserId?: boolean
  /** Checks that span rows or tables, before anything is written. */
  readonly check?: (db: D1Database, userId: string, rows: readonly Record<string, unknown>[]) => Promise<void>
}

const col = (name: string, kind: Kind): Column => ({ name, kind })
const opt = (name: string, kind: Kind): Column => ({ name, kind, nullable: true })
const edited = col('client_updated_at', 'ts')
const deleted = opt('deleted_at', 'ts')

/** A day's routine must be the caller's (Postgres: the foreign key plus RLS's with check). Tombstones count. */
async function ownRoutines(db: D1Database, userId: string, rows: readonly Record<string, unknown>[]) {
  const ids = [...new Set(rows.flatMap((r) => (typeof r.routine_id === 'string' ? [r.routine_id] : [])))]
  if (ids.length === 0) return
  const { results } = await db.prepare('SELECT id FROM routines WHERE user_id = ?1 AND id IN (SELECT value FROM json_each(?2))')
    .bind(userId, JSON.stringify(ids)).all<{ id: string }>()
  const mine = new Set(results.map((r) => r.id))
  const missing = ids.find((id) => !mine.has(id))
  if (missing !== undefined) throw new RowError(`routine_id ${missing} is not one of your routines`)
}

export const ENTITIES: Readonly<Record<string, Entity>> = {
  profile: {
    table: 'profiles',
    conflict: ['user_id'],
    ackKey: 'user_id',
    tiebreak: { column: 'user_id', kind: 'text' },
    pullsUserId: true,
    columns: [
      col('unit', 'text'), col('rest_sec', 'int'), col('warmup_rest_sec', 'int'), opt('height_cm', 'real'),
      opt('goal_weight_kg', 'real'), opt('goal_date', 'date'), col('training_days', 'int'), col('experience', 'text'),
      col('limits', 'text'), opt('limits_until', 'date'), col('deload_pct', 'real'), col('bar_kg', 'real'),
      col('plates_kg', 'json'), col('dumbbell_step_kg', 'real'), col('mcp_read_workouts', 'bool'),
      col('mcp_read_body', 'bool'), col('mcp_read_plan', 'bool'), col('mcp_read_gyms', 'bool'),
      col('mcp_propose', 'bool'), col('mcp_auto_apply', 'bool'), opt('sex', 'text'), opt('birth_year', 'int'), edited,
    ],
  },
  'custom-exercises': {
    table: 'custom_exercises',
    conflict: ['id'],
    ackKey: 'id',
    tiebreak: { column: 'id', kind: 'text' },
    columns: [
      col('id', 'text'), col('n', 'text'), col('bp', 'text'), col('eq', 'text'), col('tg', 'text'), col('mode', 'text'),
      col('bilateral', 'bool'), edited, deleted,
    ],
  },
  'exercise-prefs': {
    table: 'exercise_prefs',
    conflict: ['user_id', 'exercise_id'],
    ackKey: 'exercise_id',
    tiebreak: { column: 'exercise_id', kind: 'text' },
    columns: [col('exercise_id', 'text'), col('pref', 'text'), edited],
  },
  routines: {
    table: 'routines',
    conflict: ['id'],
    ackKey: 'id',
    tiebreak: { column: 'id', kind: 'text' },
    columns: [
      col('id', 'uuid'), col('name', 'text'), opt('emoji', 'text'), col('policy', 'text'), col('position', 'int'),
      col('paused', 'bool'), col('exercises', 'json'), edited, deleted,
    ],
  },
  weekdays: {
    table: 'week_schedule',
    conflict: ['user_id', 'weekday'],
    ackKey: 'weekday',
    tiebreak: { column: 'weekday', kind: 'int' },
    columns: [col('weekday', 'int'), opt('routine_id', 'uuid'), edited],
    check: ownRoutines,
  },
  'muscle-targets': {
    table: 'muscle_targets',
    conflict: ['user_id', 'muscle'],
    ackKey: 'muscle',
    tiebreak: { column: 'muscle', kind: 'text' },
    columns: [col('muscle', 'text'), col('min_sets', 'int'), col('max_sets', 'int'), edited],
  },
  bodyweight: {
    table: 'bodyweight',
    conflict: ['id'],
    ackKey: 'id',
    tiebreak: { column: 'id', kind: 'text' },
    columns: [
      col('id', 'uuid'), col('measured_at', 'ts'), col('w_kg', 'real'), opt('bf_pct', 'real'), opt('t', 'text'),
      opt('source', 'text'), opt('health_sample_id', 'uuid'), opt('health_fat_sample_id', 'uuid'), edited, deleted,
    ],
  },
}

export function entityNamed(name: string): Entity {
  if (!Object.hasOwn(ENTITIES, name)) throw new ApiError(404, 'not_found', `No synced table ${name}.`)
  return ENTITIES[name]
}
```

- [ ] **Step 4: Write `server/src/sync/table-sync.ts`**

```ts
import { ApiError } from '../http/errors.ts'
import { storedRow, wireRow } from './columns.ts'
import type { Entity } from './entities.ts'
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

/** The app pushes at most 200 rows at a time. */
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
export async function pushRows(db: D1Database, userId: string, entity: Entity, body: unknown): Promise<Ack[]> {
  const raw = (body as { rows?: unknown } | null)?.rows
  if (!Array.isArray(raw)) throw bad('Expected {"rows": [...]}.')
  if (raw.length > MAX_PUSH_ROWS) throw bad(`At most ${MAX_PUSH_ROWS} rows per push.`)
  const rows = raw.map((row, index) => storedRow(entity.columns, row, `rows[${index}]`))
  if (rows.length === 0) return []
  await entity.check?.(db, userId, rows)
  const json = JSON.stringify(rows)
  if (!entity.conflict.includes('user_id')) await refuseOthersRows(db, userId, entity, json)
  const { results } = await db.prepare(upsertSql(entity)).bind(json, userId)
    .all<{ id: string | number; updated_at: string }>()
  return results.map((r) => ({ id: String(r.id), updated_at: r.updated_at }))
}

/** A row id another account holds is refused outright, as Postgres's RLS refused it (42501). */
async function refuseOthersRows(db: D1Database, userId: string, entity: Entity, json: string) {
  const key = entity.conflict[0]
  const other = await db.prepare(
    `SELECT 1 FROM ${entity.table} WHERE ${key} IN (SELECT json_extract(value, '$.${key}') FROM json_each(?1)) ` +
      'AND user_id <> ?2 LIMIT 1',
  ).bind(json, userId).first()
  if (other) throw new ApiError(403, 'not_allowed', 'That row belongs to another account.')
}

export function upsertSql(entity: Entity): string {
  const names = entity.columns.map((c) => c.name)
  const updates = names.filter((n) => !entity.conflict.includes(n))
    .map((n) => `${n} = ${entity.onUpdate?.[n] ?? `excluded.${n}`}`)
  const applies = entity.applies ?? `excluded.client_updated_at >= ${entity.table}.client_updated_at`
  const stampSql = `updated_at = ${laterStamp(`${entity.table}.updated_at`, 'excluded.updated_at')}`
  return `INSERT INTO ${entity.table} (user_id, ${names.join(', ')}, updated_at)
SELECT ?2, ${names.map((n) => `json_extract(value, '$.${n}')`).join(', ')}, ${NOW_SQL} FROM json_each(?1) WHERE true
ON CONFLICT (${entity.conflict.join(', ')}) DO UPDATE SET ${[...updates, stampSql].join(', ')}
WHERE ${entity.table}.user_id = excluded.user_id AND (${applies})
RETURNING ${entity.ackKey} AS id, updated_at`
}

/** One page of the caller's rows, oldest change first, tombstones included. */
export async function pullRows(db: D1Database, userId: string, entity: Entity, query: PullQuery) {
  const select = [...(entity.pullsUserId ? ['user_id'] : []), ...entity.columns.map((c) => c.name), 'updated_at']
  const { results } = await db.prepare(
    `SELECT ${select.join(', ')} FROM ${entity.table} WHERE user_id = ?1 AND ${afterSql(entity.tiebreak.column)} ` +
      `ORDER BY updated_at, ${entity.tiebreak.column} LIMIT ?4`,
  ).bind(userId, query.since, query.after, query.limit).all<Record<string, unknown>>()
  return results.map((row) => wireRow(entity.columns, row))
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

- [ ] **Step 5: Write the routes and mount them**

`server/src/sync/routes.ts`:

```ts
import { Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { jsonBody } from '../http/body.ts'
import { entityNamed } from './entities.ts'
import { parsePullQuery, pullRows, pushRows } from './table-sync.ts'

/** /v1/sync: what the app's SyncTransport calls (spec section 3, "Routes"). Specific routes go above /:entity. */
export const syncRoutes = new Hono<AppEnv>()

syncRoutes.post('/:entity', async (c) => {
  const acks = await pushRows(c.env.DB, c.var.userId, entityNamed(c.req.param('entity')), await jsonBody(c))
  return c.json({ acks })
})

syncRoutes.get('/:entity', async (c) => {
  const entity = entityNamed(c.req.param('entity'))
  const rows = await pullRows(c.env.DB, c.var.userId, entity, parsePullQuery(c.req.query(), entity.tiebreak.kind))
  return c.json({ rows })
})
```

Replace `server/src/index.ts` with:

```ts
// The GymRollins API (docs/specs/2026-11-07-cloudflare-backend-design.md): one Worker, with Better Auth under /api/auth
// and the app's routes under /v1 behind its session.
import { Hono } from 'hono'
import { bodyLimit } from 'hono/body-limit'
import { authHandler } from './auth/routes.ts'
import { requireUser } from './auth/session.ts'
import type { AppEnv } from './env.ts'
import { errorBody, onError } from './http/errors.ts'
import { syncRoutes } from './sync/routes.ts'

/** A workout or 200 rows is far below this, and one bound JSON value must stay under D1's ~2 MB. */
const MAX_BODY_BYTES = 1024 * 1024

const app = new Hono<AppEnv>()
app.onError(onError)
app.notFound((c) => c.json(errorBody('not_found', 'No such route.'), 404))
app.on(['GET', 'POST'], '/api/auth/*', authHandler)

const v1 = new Hono<AppEnv>()
v1.use('*', bodyLimit({
  maxSize: MAX_BODY_BYTES,
  onError: (c) => c.json(errorBody('too_large', 'The request body is too large.'), 413),
}))
v1.use('*', requireUser)
v1.route('/sync', syncRoutes)
app.route('/v1', v1)

export default app
```

- [ ] **Step 6: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected:
- `Test Files  7 passed (7)` and `Tests  103 passed (103)`.
- `sync-rows.test.ts` adds 49 tests: 35 for the seven tables and 14 more. Step 8 adds 7, for 110.

- [ ] **Step 7: Commit**

```bash
git add server
git commit -m "feat(server): row sync for the profile, plan and body weight"
```

- [ ] **Step 8: The review follow-ups (added after review)**

**Changes:**
- An empty `after` is refused, and an int `after` must be digits.
- The body limit is 1 MiB: a push is one bound JSON value, and D1 caps one at about 2 MB.
- `upsertSql` is exported for a test.

**Seven tests added to `sync-rows.test.ts`:**
- The upsert's own owner `WHERE`, run without the pre-check. Removing the condition makes this test fail.
- The same key twice in one push.
- A pulled tombstone.
- A day going back to rest.
- A day on a tombstoned routine.
- The 413.
- An empty and a non-numeric `after`.

With them: `Tests  110 passed (110)`. Commit: `test(server): row sync review follow-ups (owner guard, duplicates, tombstones, limits)`.

### Task 6: Body weight from Apple Health

Postgres ran `health_tombstone_guard` before last-write-wins on `bodyweight`:
- a weigh-in Health deleted stays deleted,
- Health's deletion beats an edit newer than itself, keeping that edit's time.

**Files:**
- Modify: `server/src/sync/entities.ts`
- Test: `server/test/sync-bodyweight.test.ts`

- [ ] **Step 1: Write the failing tests**

`server/test/sync-bodyweight.test.ts`:

```ts
import { describe, expect, it } from 'vitest'
import { request, signUp } from './helpers.ts'
import { appUUID, type Row, SAMPLES, T1, T2 } from './samples.ts'

async function acks(token: string, rows: Row[]): Promise<unknown[]> {
  const res = await request('POST', '/v1/sync/bodyweight', { token, body: { rows } })
  expect(res.status).toBe(200)
  return (await res.json<{ acks: unknown[] }>()).acks
}

async function stored(token: string): Promise<Row> {
  const res = await request('GET', '/v1/sync/bodyweight', { token })
  const { rows } = await res.json<{ rows: Row[] }>()
  expect(rows).toHaveLength(1)
  return rows[0]
}

const fromHealth = (): Row => ({ ...SAMPLES.bodyweight(), source: 'apple_health', health_sample_id: appUUID() })

describe('body weight from Apple Health', () => {
  it('keeps a weigh-in Health deleted deleted, even against a newer live edit', async () => {
    const { token } = await signUp()
    const row = fromHealth()
    await acks(token, [{ ...row, client_updated_at: T1, deleted_at: T1 }])
    expect(await acks(token, [{ ...row, client_updated_at: T2, deleted_at: null }])).toEqual([])
    expect((await stored(token)).deleted_at).toBe(T1)
  })

  it("lets Health's deletion win over a newer edit, keeping the newer edit's time", async () => {
    const { token } = await signUp()
    const row = fromHealth()
    await acks(token, [{ ...row, client_updated_at: T2 }])
    expect(await acks(token, [{ ...row, client_updated_at: T1, deleted_at: T1 }])).toHaveLength(1)
    const now = await stored(token)
    expect(now.deleted_at).toBe(T1)
    expect(now.client_updated_at).toBe(T2)
  })

  it('counts the sample id a deletion brings with it', async () => {
    const { token } = await signUp()
    const row = SAMPLES.bodyweight()
    await acks(token, [{ ...row, client_updated_at: T2 }])
    const deletion = { ...row, health_sample_id: appUUID(), client_updated_at: T1, deleted_at: T1 }
    expect(await acks(token, [deletion])).toHaveLength(1)
  })

  it('treats a weigh-in from the app by plain last-write-wins', async () => {
    const { token } = await signUp()
    const row = SAMPLES.bodyweight()
    await acks(token, [{ ...row, client_updated_at: T2 }])
    expect(await acks(token, [{ ...row, client_updated_at: T1, deleted_at: T1 }])).toEqual([])
    expect((await stored(token)).deleted_at).toBeNull()
    expect(await acks(token, [{ ...row, client_updated_at: T2, deleted_at: T2 }])).toHaveLength(1)
    expect(await acks(token, [{ ...row, client_updated_at: '2026-11-07T12:00:00.000000Z', deleted_at: null }]))
      .toHaveLength(1)
    expect((await stored(token)).deleted_at).toBeNull()
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/sync-bodyweight.test.ts`
Expected:
- FAIL: the first two tests fail. The live edit gets an ack (`expected [ …1 item… ] to deeply equal []`), and the older deletion gets none (`expected [] to have a length of 1`).
- The third also fails.
- The fourth passes.

- [ ] **Step 3: Add the Health rules to the `bodyweight` entity**

In `server/src/sync/entities.ts`, above `ENTITIES`:

```ts
/**
 * A deletion that comes with an Apple Health sample id, of a weigh-in still live: Health's deletion, which wins over
 * a newer edit (Postgres's health_tombstone_guard, which ran before last-write-wins).
 */
const HEALTH_DELETION = '(excluded.deleted_at IS NOT NULL AND bodyweight.deleted_at IS NULL ' +
  'AND coalesce(bodyweight.health_sample_id, excluded.health_sample_id) IS NOT NULL)'
/** A weigh-in Health deleted stays deleted: a live edit of it is skipped. */
const HEALTH_DELETED = '(bodyweight.deleted_at IS NOT NULL AND bodyweight.health_sample_id IS NOT NULL ' +
  'AND excluded.deleted_at IS NULL)'
```

and add these two fields to the `bodyweight` entry:

```ts
    applies: `NOT ${HEALTH_DELETED} AND (excluded.client_updated_at >= bodyweight.client_updated_at OR ${HEALTH_DELETION})`,
    onUpdate: {
      client_updated_at: `CASE WHEN ${HEALTH_DELETION} ` +
        'THEN max(excluded.client_updated_at, bodyweight.client_updated_at) ELSE excluded.client_updated_at END',
    },
```

- [ ] **Step 4: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  8 passed (8)`, `Tests  114 passed (114)`.

- [ ] **Step 5: Commit**

```bash
git add server/src/sync/entities.ts server/test/sync-bodyweight.test.ts
git commit -m "feat(server): Apple Health deletions in body weight sync"
```

### Task 7: Gym links

A saved workout may name a gym, and each entry may name a listing (a machine at that gym). The workout save keeps or drops each link by the Postgres rules (`upsert_workout`, `workout_gym_link`, `workout_entry_gym_link`, and the read policies of `20261030000001_gyms.sql`). The visibility rules go in `src/gyms/visibility.ts`; plans 28 and 29 build on them.

**Files:**
- Create: `server/src/gyms/visibility.ts`, `server/src/sync/gym-links.ts`, `server/test/gym-fixtures.ts`
- Test: `server/test/gym-links.test.ts`

- [ ] **Step 1: Write the fixtures and the failing tests**

`server/test/gym-fixtures.ts`:

```ts
import { env } from 'cloudflare:workers'

// Gym rows written straight into D1. Plan 28 adds the routes that create them.

const T = '2026-11-07T10:00:00.000000Z'
type Status = 'active' | 'flagged' | 'removed'

export async function insertGym(g: {
  visibility: 'public' | 'private'
  owner?: string
  createdBy?: string
  status?: Status
}): Promise<string> {
  const id = crypto.randomUUID()
  await env.DB.prepare(
    'INSERT INTO gyms (id, visibility, owner_id, name, maps_place_id, created_by, status, client_updated_at, ' +
      "created_at, updated_at) VALUES (?1, ?2, ?3, 'Test gym', ?4, ?5, ?6, ?7, ?7, ?7)",
  ).bind(
    id,
    g.visibility,
    g.visibility === 'private' ? (g.owner ?? null) : null,
    g.visibility === 'public' ? `place-${id}` : null,
    g.createdBy ?? null,
    g.status ?? 'active',
    T,
  ).run()
  return id
}

/** The seeded generic item of a kind. */
export async function genericItem(kind = 'dumbbells'): Promise<string> {
  const row = await env.DB.prepare('SELECT id FROM equipment_items WHERE kind_id = ?1 AND brand IS NULL AND model IS NULL')
    .bind(kind).first<{ id: string }>()
  return row!.id
}

export async function insertItem(i: { brand: string; model: string; createdBy: string; kind?: string }): Promise<string> {
  const id = crypto.randomUUID()
  await env.DB.prepare(
    'INSERT INTO equipment_items (id, kind_id, brand, model, created_by, created_at, updated_at) ' +
      'VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)',
  ).bind(id, i.kind ?? 'dumbbells', i.brand, i.model, i.createdBy, T).run()
  return id
}

export async function insertListing(l: {
  gym: string
  item: string
  visibility: 'public' | 'private'
  owner?: string
  addedBy?: string
  status?: Status
  notes?: string
  photo?: string
}): Promise<string> {
  const id = crypto.randomUUID()
  await env.DB.prepare(
    'INSERT INTO gym_equipment (id, gym_id, item_id, visibility, owner_id, photo_path, notes, added_by, status, ' +
      'client_updated_at, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10, ?10)',
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
  ).run()
  return id
}

export async function setStatus(table: 'gyms' | 'gym_equipment' | 'equipment_items', id: string, status: Status) {
  await env.DB.prepare(`UPDATE ${table} SET status = ?2 WHERE id = ?1`).bind(id, status).run()
}

export async function makeAdmin(userId: string) {
  await env.DB.prepare('INSERT INTO app_admins (user_id, created_at) VALUES (?1, ?2)').bind(userId, T).run()
}

export async function block(blocker: string, blocked: string) {
  await env.DB.prepare('INSERT INTO user_blocks (blocker_id, blocked_id, created_at) VALUES (?1, ?2, ?3)')
    .bind(blocker, blocked, T).run()
}
```

`server/test/gym-links.test.ts`:

```ts
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { entryListings, workoutGym } from '../src/sync/gym-links.ts'
import { block, genericItem, insertGym, insertListing, makeAdmin, setStatus } from './gym-fixtures.ts'
import { signUp } from './helpers.ts'

const db = env.DB
const linkTo = (userId: string, gym: string) => workoutGym(db, userId, null, gym)
const entry = (id: string, gymEquipmentId: string | null) => ({ id, gymEquipmentId })

describe("a workout's gym", () => {
  it('takes a gym you can read: your private gym, or an active public one', async () => {
    const { userId } = await signUp()
    const mine = await insertGym({ visibility: 'private', owner: userId })
    const open = await insertGym({ visibility: 'public' })
    expect(await linkTo(userId, mine)).toBe(mine)
    expect(await linkTo(userId, open)).toBe(open)
  })

  it("drops one you can't: another account's private gym, a removed gym, a flagged gym you didn't add", async () => {
    const me = await signUp()
    const other = await signUp()
    expect(await linkTo(me.userId, await insertGym({ visibility: 'private', owner: other.userId }))).toBeNull()
    expect(await linkTo(me.userId, await insertGym({ visibility: 'public', status: 'removed' }))).toBeNull()
    const flagged = await insertGym({ visibility: 'public', status: 'flagged', createdBy: other.userId })
    expect(await linkTo(me.userId, flagged)).toBeNull()
  })

  it('lets a flagged gym through to whoever added it, and any public gym to an admin', async () => {
    const me = await signUp()
    const admin = await signUp()
    await makeAdmin(admin.userId)
    const flagged = await insertGym({ visibility: 'public', status: 'flagged', createdBy: me.userId })
    expect(await linkTo(me.userId, flagged)).toBe(flagged)
    const removed = await insertGym({ visibility: 'public', status: 'removed' })
    expect(await linkTo(admin.userId, removed)).toBe(removed)
  })

  it('keeps the stored gym when the phone sends none or the same one, while it survives', async () => {
    const me = await signUp()
    const other = await signUp()
    const gym = await insertGym({ visibility: 'public', status: 'flagged', createdBy: other.userId })
    expect(await workoutGym(db, me.userId, gym, null)).toBe(gym)
    expect(await workoutGym(db, me.userId, gym, gym)).toBe(gym)
  })

  it('drops a stored gym once it is removed, even when the phone sends it again', async () => {
    const { userId } = await signUp()
    const gym = await insertGym({ visibility: 'public' })
    await setStatus('gyms', gym, 'removed')
    expect(await workoutGym(db, userId, gym, null)).toBeNull()
    expect(await workoutGym(db, userId, gym, gym)).toBeNull()
  })

  it('replaces the stored gym with a new one you can read, or with nothing', async () => {
    const me = await signUp()
    const other = await signUp()
    const old = await insertGym({ visibility: 'public' })
    const next = await insertGym({ visibility: 'public' })
    expect(await workoutGym(db, me.userId, old, next)).toBe(next)
    const hidden = await insertGym({ visibility: 'private', owner: other.userId })
    expect(await workoutGym(db, me.userId, old, hidden)).toBeNull()
  })
})

describe("an entry's listing", () => {
  it('takes a listing you can read: active on an active gym and item, or your own private one', async () => {
    const { userId } = await signUp()
    const item = await genericItem()
    const open = await insertListing({ gym: await insertGym({ visibility: 'public' }), item, visibility: 'public' })
    const myGym = await insertGym({ visibility: 'private', owner: userId })
    const mine = await insertListing({ gym: myGym, item, visibility: 'private', owner: userId })
    const links = await entryListings(db, userId, [entry('a', open), entry('b', mine)], new Map())
    expect(Object.fromEntries(links)).toEqual({ a: open, b: mine })
  })

  it("drops one under a flagged gym, by an author you blocked, or another account's private one", async () => {
    const me = await signUp()
    const other = await signUp()
    const item = await genericItem()
    const flaggedGym = await insertGym({ visibility: 'public', status: 'flagged' })
    const underFlagged = await insertListing({ gym: flaggedGym, item, visibility: 'public' })
    const openGym = await insertGym({ visibility: 'public' })
    const byBlocked = await insertListing({ gym: openGym, item, visibility: 'public', addedBy: other.userId })
    await block(me.userId, other.userId)
    const theirGym = await insertGym({ visibility: 'private', owner: other.userId })
    const theirs = await insertListing({ gym: theirGym, item, visibility: 'private', owner: other.userId })
    const links = await entryListings(
      db,
      me.userId,
      [entry('a', underFlagged), entry('b', byBlocked), entry('c', theirs)],
      new Map(),
    )
    expect(Object.fromEntries(links)).toEqual({ a: null, b: null, c: null })
  })

  it('keeps the previous listing when the phone leaves it out, while it survives', async () => {
    const me = await signUp()
    const other = await signUp()
    const gym = await insertGym({ visibility: 'public' })
    const listing = await insertListing({
      gym, item: await genericItem(), visibility: 'public', addedBy: other.userId, status: 'flagged',
    })
    const links = await entryListings(db, me.userId, [entry('a', null)], new Map([['a', listing]]))
    expect(links.get('a')).toBe(listing)
  })

  it('drops the previous listing once it is removed', async () => {
    const { userId } = await signUp()
    const gym = await insertGym({ visibility: 'public' })
    const listing = await insertListing({ gym, item: await genericItem(), visibility: 'public' })
    await setStatus('gym_equipment', listing, 'removed')
    const links = await entryListings(db, userId, [entry('a', null)], new Map([['a', listing]]))
    expect(links.get('a')).toBeNull()
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/gym-links.test.ts`
Expected: FAIL with `Failed to load url ../src/sync/gym-links.ts`.

- [ ] **Step 3: Write `server/src/gyms/visibility.ts`**

```ts
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
```

- [ ] **Step 4: Write `server/src/sync/gym-links.ts`**

```ts
import { gymLinkSurvives, gymReadable, listingLinkSurvives, listingReadable } from '../gyms/visibility.ts'

/** The ids among `ids` whose row in `table` (as `alias`) meets `condition`, which reads the caller as ?2. */
async function idsWhere(
  db: D1Database,
  table: string,
  alias: string,
  condition: string,
  userId: string,
  ids: readonly string[],
): Promise<Set<string>> {
  if (ids.length === 0) return new Set()
  const { results } = await db.prepare(
    `SELECT ${alias}.id FROM ${table} ${alias} WHERE ${alias}.id IN (SELECT value FROM json_each(?1)) AND ${condition}`,
  ).bind(JSON.stringify(ids), userId).all<{ id: string }>()
  return new Set(results.map((r) => r.id))
}

/**
 * The gym a saved workout keeps. A link the phone left out or sent again stays while it survives: the phone can't
 * unset a gym, so null means "unknown here". A new link is taken only if the caller can read that gym.
 */
export async function workoutGym(
  db: D1Database,
  userId: string,
  stored: string | null,
  incoming: string | null,
): Promise<string | null> {
  if (incoming === null || incoming === stored) {
    if (stored === null) return null
    return (await idsWhere(db, 'gyms', 'g', gymLinkSurvives('g'), userId, [stored])).has(stored) ? stored : null
  }
  return (await idsWhere(db, 'gyms', 'g', gymReadable('g'), userId, [incoming])).has(incoming) ? incoming : null
}

export interface EntryLink {
  readonly id: string
  readonly gymEquipmentId: string | null
}

/**
 * Each saved entry's listing: the phone's, or else the entry's previous one. The previous listing is kept while it
 * survives; any other is taken only if the caller can read it.
 */
export async function entryListings(
  db: D1Database,
  userId: string,
  entries: readonly EntryLink[],
  previous: ReadonlyMap<string, string>,
): Promise<Map<string, string | null>> {
  const wanted = entries.map((e) => ({ id: e.id, listing: e.gymEquipmentId ?? previous.get(e.id) ?? null }))
  const listings = [...new Set(wanted.flatMap((w) => (w.listing === null ? [] : [w.listing])))]
  const [surviving, readable] = await Promise.all([
    idsWhere(db, 'gym_equipment', 'e', listingLinkSurvives('e'), userId, listings),
    idsWhere(db, 'gym_equipment', 'e', listingReadable('e'), userId, listings),
  ])
  return new Map(wanted.map(({ id, listing }): [string, string | null] => {
    if (listing === null) return [id, null]
    const kept = previous.get(id) === listing && surviving.has(listing)
    return [id, kept || readable.has(listing) ? listing : null]
  }))
}
```

- [ ] **Step 5: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  9 passed (9)`, `Tests  124 passed (124)`.

- [ ] **Step 6: Commit**

```bash
git add server/src/gyms server/src/sync/gym-links.ts server/test/gym-fixtures.ts server/test/gym-links.test.ts
git commit -m "feat(server): gym and listing links for workouts"
```

- [ ] **Step 7: The review follow-up (added after review): a test for every rule**

The review found the rules faithful to Postgres. It also found clauses that no test would miss if deleted, so `gym-links.test.ts` gains 8 tests:
- an admin sees any public listing;
- a flagged listing is shown to whoever added it;
- items that are flagged or removed hide their listings;
- a previous link to a blocked author's listing is dropped;
- a previous link is dropped once its gym or item is removed, or when it points at another account's private listing;
- an admin still can't see another account's private gym or listing;
- a block applies only to whoever made it;
- a different new listing replaces the previous one, and a listing shared by two entries is read once;
- stored links: one to another account's private gym is dropped, and one to a flagged gym with no creator is kept.

With them: `Tests  132 passed (132)`. Removing the admin clause makes a test fail. Commit: `test(server): cover every gym and listing visibility rule`.

### Task 8: Workouts

`POST /v1/sync/workouts` is `upsert_workout`. `GET /v1/sync/workouts` and `/v1/sync/workouts/:id` answer workouts with `entries[]` and `sets[]` nested, as the app decodes them.

**Files:**
- Create: `server/src/sync/workouts.ts`
- Modify: `server/src/sync/routes.ts`, `server/test/samples.ts`
- Test: `server/test/sync-workouts.test.ts`

- [ ] **Step 1: Write the sample and the failing tests**

Append to `server/test/samples.ts`:

```ts
/** A workout as the tests build and read it: loosely typed, like the JSON. */
export type WorkoutJSON = Record<string, any> & { id: string; entries: Array<Record<string, any>> }

/** A workout push as the app encodes it (WorkoutDTO): nested entries and sets, the set's nil optionals left out. */
export function workoutSample(overrides: Record<string, unknown> = {}): WorkoutJSON {
  return {
    id: appUUID(),
    started_at: '2026-11-07T09:00:00.000000Z',
    ended_at: '2026-11-07T10:00:00.000000Z',
    paused_sec: 0,
    routine_id: null,
    name: 'Push',
    source: 'app',
    note: null,
    vol_kg: 960,
    records: [{ exerciseId: 'bench_press', kind: 'e1RM', valueKg: 75 }],
    entries: [{
      id: appUUID(),
      exercise_id: 'bench_press',
      position: 0,
      note: null,
      superset_group: null,
      sets: [
        { id: appUUID(), position: 0, w_kg: 60, r: 8, done: true, warmup: false, multiplier: 1 },
        { id: appUUID(), position: 1, w_kg: 60, r: 8, done: true, warmup: false, multiplier: 1, rir: 2 },
      ],
    }],
    client_updated_at: T1,
    deleted_at: null,
    base_updated_at: null,
    force: false,
    ...overrides,
  }
}
```

`server/test/sync-workouts.test.ts`:

```ts
import { describe, expect, it } from 'vitest'
import { genericItem, insertGym, insertListing } from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'
import { appUUID, T0, T1, T2, type WorkoutJSON, workoutSample } from './samples.ts'

interface Saved {
  status: 'ok' | 'stale'
  updated_at: string
}

const T3 = '2026-11-07T12:00:00.000000Z'

async function save(token: string, workout: unknown): Promise<Saved> {
  const res = await request('POST', '/v1/sync/workouts', { token, body: workout })
  expect(res.status).toBe(200)
  return res.json<Saved>()
}

async function fetchOne(token: string, id: string): Promise<WorkoutJSON> {
  const res = await request('GET', `/v1/sync/workouts/${id}`, { token })
  expect(res.status).toBe(200)
  return res.json<WorkoutJSON>()
}

async function pullPage(token: string, query: string): Promise<WorkoutJSON[]> {
  const res = await request('GET', `/v1/sync/workouts${query}`, { token })
  expect(res.status).toBe(200)
  return (await res.json<{ rows: WorkoutJSON[] }>()).rows
}

describe('saving a workout', () => {
  it('stores it with its entries and sets, and answers it as the app decodes it', async () => {
    const { token } = await signUp()
    const w = workoutSample()
    const saved = await save(token, w)
    expect(saved.status).toBe('ok')
    const [entry] = w.entries
    expect(await fetchOne(token, w.id)).toEqual({
      id: w.id.toLowerCase(), started_at: w.started_at, ended_at: w.ended_at, paused_sec: 0, routine_id: null,
      name: 'Push', source: 'app', note: null, vol_kg: 960, records: w.records, gym_id: null, client_updated_at: T1,
      deleted_at: null, updated_at: saved.updated_at,
      entries: [{
        id: entry.id.toLowerCase(), exercise_id: 'bench_press', position: 0, note: null, superset_group: null,
        gym_equipment_id: null,
        sets: entry.sets.map((s: Record<string, unknown>) => ({
          sec: null, min: null, dist_m: null, rir: null, rpe: null, completed_at: null, ...s,
          id: String(s.id).toLowerCase(),
        })),
      }],
    })
  })

  it('fills in what upsert_workout defaulted', async () => {
    const { token } = await signUp()
    const id = appUUID()
    await save(token, {
      id, started_at: T0, name: 'Bare', client_updated_at: T1, base_updated_at: null, force: false,
      entries: [{ id: appUUID(), exercise_id: 'squat', position: 0, sets: [{ id: appUUID(), position: 0, w_kg: 100, r: 5 }] }],
    })
    const stored = await fetchOne(token, id)
    expect(stored).toMatchObject({ paused_sec: 0, source: 'app', vol_kg: 0, records: [], ended_at: null, deleted_at: null })
    expect(stored.entries[0].sets[0]).toMatchObject({ done: false, warmup: false, multiplier: 1 })
  })

  it('replaces the entries and sets with each save on the latest version', async () => {
    const { token } = await signUp()
    const w = workoutSample()
    const first = await save(token, w)
    const entry = { id: appUUID(), exercise_id: 'row', position: 0, note: 'new', superset_group: null, sets: [] }
    const second = await save(token, {
      ...w, name: 'Pull', entries: [entry], client_updated_at: T2, base_updated_at: first.updated_at,
    })
    expect(second.status).toBe('ok')
    expect(second.updated_at > first.updated_at).toBe(true)
    const stored = await fetchOne(token, w.id)
    expect(stored.name).toBe('Pull')
    expect(stored.entries.map((e) => e.id)).toEqual([entry.id.toLowerCase()])
    expect(stored.updated_at).toBe(second.updated_at)
  })

  it("answers stale when another phone saved since this edit's version, and changes nothing", async () => {
    const { token } = await signUp()
    const w = workoutSample()
    const first = await save(token, w)
    const other = await save(token, {
      ...w, name: 'From the other phone', client_updated_at: T2, base_updated_at: first.updated_at,
    })
    expect(other.status).toBe('ok')
    const late = await save(token, {
      ...w, name: 'From this phone', client_updated_at: T3, base_updated_at: first.updated_at,
    })
    expect(late).toEqual({ status: 'stale', updated_at: other.updated_at })
    expect((await fetchOne(token, w.id)).name).toBe('From the other phone')
  })

  it('answers stale for an edit older than the stored one', async () => {
    const { token } = await signUp()
    const w = workoutSample({ client_updated_at: T2 })
    const first = await save(token, w)
    expect(await save(token, { ...w, client_updated_at: T1, base_updated_at: first.updated_at }))
      .toEqual({ status: 'stale', updated_at: first.updated_at })
  })

  it('takes the retry of a save whose answer was lost, but no other edit without a version', async () => {
    const { token } = await signUp()
    const w = workoutSample()
    await save(token, w)
    expect((await save(token, w)).status).toBe('ok')
    expect((await save(token, { ...w, client_updated_at: T2 })).status).toBe('stale')
  })

  it("lets Keep this iPhone's overwrite, keeping the later edit time", async () => {
    const { token } = await signUp()
    const w = workoutSample({ client_updated_at: T2 })
    await save(token, w)
    const forced = await save(token, { ...w, name: 'Mine', client_updated_at: T1, force: true })
    expect(forced.status).toBe('ok')
    expect(await fetchOne(token, w.id)).toMatchObject({ name: 'Mine', client_updated_at: T2 })
  })

  it("refuses another account's workout id", async () => {
    const a = await signUp()
    const b = await signUp()
    const w = workoutSample()
    await save(a.token, w)
    const res = await request('POST', '/v1/sync/workouts', { token: b.token, body: { ...w, name: 'Taken', force: true } })
    expect(res.status).toBe(403)
    expect(await res.json()).toMatchObject({ error: { code: 'not_allowed' } })
    expect((await fetchOne(a.token, w.id)).name).toBe('Push')
  })

  it('refuses a set that breaks a rule, and keeps the stored workout whole', async () => {
    const { token } = await signUp()
    const w = workoutSample()
    const first = await save(token, w)
    const bad = structuredClone(w)
    bad.entries[0].sets[0].w_kg = 2000
    const res = await request('POST', '/v1/sync/workouts', {
      token, body: { ...bad, client_updated_at: T2, base_updated_at: first.updated_at },
    })
    expect(res.status).toBe(422)
    expect(await res.json()).toMatchObject({ error: { code: 'row_rejected' } })
    const stored = await fetchOne(token, w.id)
    expect(stored.updated_at).toBe(first.updated_at)
    expect(stored.entries[0].sets).toHaveLength(2)
  })

  it('refuses a value of the wrong type, saying where it is', async () => {
    const { token } = await signUp()
    const bad = workoutSample()
    bad.entries[0].sets[0].r = 'eight'
    const res = await request('POST', '/v1/sync/workouts', { token, body: bad })
    expect(res.status).toBe(422)
    expect(await res.json()).toEqual({
      error: { code: 'row_rejected', message: 'workout.entries[0].sets[0].r is not a valid int' },
    })
  })
})

describe('pulling workouts', () => {
  it('pages them with their entries, deleted ones included', async () => {
    const { token } = await signUp()
    const ids: string[] = []
    for (const deleted of [null, null, T1]) {
      const w = workoutSample({ deleted_at: deleted })
      await save(token, w)
      ids.push(w.id.toLowerCase())
    }
    const first = await pullPage(token, '?limit=2')
    expect(first).toHaveLength(2)
    const last = first[1]
    const rest = await pullPage(token, `?limit=2&since=${encodeURIComponent(last.updated_at)}&after=${last.id}`)
    const all = [...first, ...rest]
    expect(all.map((w) => w.id).sort()).toEqual(ids.sort())
    expect(all.every((w) => w.entries.length === 1 && w.entries[0].sets.length === 2)).toBe(true)
    expect(all.filter((w) => w.deleted_at !== null)).toHaveLength(1)
  })

  it("fetches one by id in either case, and answers 404 for one that isn't yours", async () => {
    const a = await signUp()
    const b = await signUp()
    const w = workoutSample()
    await save(a.token, w)
    expect((await fetchOne(a.token, w.id.toUpperCase())).id).toBe(w.id.toLowerCase())
    expect((await request('GET', `/v1/sync/workouts/${w.id}`, { token: b.token })).status).toBe(404)
    expect((await request('GET', `/v1/sync/workouts/${crypto.randomUUID()}`, { token: a.token })).status).toBe(404)
  })
})

describe("a workout's gym and listings", () => {
  it("keeps a gym and listing you can read, and drops ones you can't", async () => {
    const me = await signUp()
    const other = await signUp()
    const mine = await insertGym({ visibility: 'private', owner: me.userId })
    const listing = await insertListing({ gym: mine, item: await genericItem(), visibility: 'private', owner: me.userId })
    const w = workoutSample({ gym_id: mine.toUpperCase() })
    w.entries[0].gym_equipment_id = listing
    await save(me.token, w)
    const stored = await fetchOne(me.token, w.id)
    expect(stored.gym_id).toBe(mine)
    expect(stored.entries[0].gym_equipment_id).toBe(listing)
    const hidden = workoutSample({ gym_id: await insertGym({ visibility: 'private', owner: other.userId }) })
    await save(me.token, hidden)
    expect((await fetchOne(me.token, hidden.id)).gym_id).toBeNull()
  })

  it('keeps the stored links when the phone sends none', async () => {
    const me = await signUp()
    const gym = await insertGym({ visibility: 'public' })
    const listing = await insertListing({ gym, item: await genericItem(), visibility: 'public' })
    const w = workoutSample({ gym_id: gym })
    w.entries[0].gym_equipment_id = listing
    const first = await save(me.token, w)
    const { gym_id: _gym, ...unlinked } = w
    const entries = w.entries.map(({ gym_equipment_id: _listing, ...e }) => e)
    await save(me.token, { ...unlinked, entries, client_updated_at: T2, base_updated_at: first.updated_at })
    const stored = await fetchOne(me.token, w.id)
    expect(stored.gym_id).toBe(gym)
    expect(stored.entries[0].gym_equipment_id).toBe(listing)
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/sync-workouts.test.ts`
Expected: FAIL. Every test gets `404` where it expects `200`, because `/v1/sync/workouts` is answered by `/:entity` with "No synced table workouts".

- [ ] **Step 3: Write `server/src/sync/workouts.ts`**

```ts
import { ApiError } from '../http/errors.ts'
import { type Column, RowError, storedRow, wireRow } from './columns.ts'
import { entryListings, workoutGym } from './gym-links.ts'
import { afterSql, type PullQuery } from './table-sync.ts'
import { laterStamp, NOW_SQL } from './time.ts'

// Workouts sync as a whole: the row, its entries and their sets, as upsert_workout stored them
// (supabase/migrations/20261030000005_workout_gym_links.sql). The fallbacks are its coalesce(…) defaults.

const WORKOUT: readonly Column[] = [
  { name: 'id', kind: 'uuid' },
  { name: 'started_at', kind: 'ts' },
  { name: 'ended_at', kind: 'ts', nullable: true },
  { name: 'paused_sec', kind: 'real', fallback: 0 },
  { name: 'routine_id', kind: 'uuid', nullable: true },
  { name: 'name', kind: 'text' },
  { name: 'source', kind: 'text', fallback: 'app' },
  { name: 'note', kind: 'text', nullable: true },
  { name: 'vol_kg', kind: 'real', fallback: 0 },
  { name: 'records', kind: 'json', fallback: [] },
  { name: 'gym_id', kind: 'uuid', nullable: true },
  { name: 'client_updated_at', kind: 'ts' },
  { name: 'deleted_at', kind: 'ts', nullable: true },
]

const ENTRY: readonly Column[] = [
  { name: 'id', kind: 'uuid' },
  { name: 'exercise_id', kind: 'text' },
  { name: 'position', kind: 'int' },
  { name: 'note', kind: 'text', nullable: true },
  { name: 'superset_group', kind: 'text', nullable: true },
  { name: 'gym_equipment_id', kind: 'uuid', nullable: true },
]

const SET: readonly Column[] = [
  { name: 'id', kind: 'uuid' },
  { name: 'position', kind: 'int' },
  { name: 'w_kg', kind: 'real' },
  { name: 'r', kind: 'int' },
  { name: 'sec', kind: 'int', nullable: true },
  { name: 'min', kind: 'real', nullable: true },
  { name: 'dist_m', kind: 'real', nullable: true },
  { name: 'done', kind: 'bool', fallback: false },
  { name: 'warmup', kind: 'bool', fallback: false },
  { name: 'rir', kind: 'real', nullable: true },
  { name: 'rpe', kind: 'real', nullable: true },
  { name: 'multiplier', kind: 'real', fallback: 1 },
  { name: 'completed_at', kind: 'ts', nullable: true },
]

/** Push only: the server version this edit was made on, and Keep this iPhone's. */
const PUSH_ONLY: readonly Column[] = [
  { name: 'base_updated_at', kind: 'ts', nullable: true },
  { name: 'force', kind: 'bool', fallback: false },
]

const names = (columns: readonly Column[]) => columns.map((c) => c.name).join(', ')
const extracted = (columns: readonly Column[]) => columns.map((c) => `json_extract(value, '$.${c.name}')`).join(', ')

/** Entries and sets are written only while the workout row is still this save's: ?1 the workout, ?2 the write id. */
const STILL_THIS_SAVE = 'EXISTS (SELECT 1 FROM workouts WHERE id = ?1 AND write_id = ?2)'

const UPSERT = `INSERT INTO workouts (${names(WORKOUT)}, user_id, write_id, updated_at)
VALUES (${WORKOUT.map((_, i) => `?${i + 1}`).join(', ')}, ?14, ?15, ${NOW_SQL})
ON CONFLICT (id) DO UPDATE SET ${WORKOUT.filter((c) => c.name !== 'id').map((c) => `${c.name} = excluded.${c.name}`).join(', ')},
  write_id = excluded.write_id, updated_at = ${laterStamp('workouts.updated_at', 'excluded.updated_at')}
WHERE workouts.user_id = excluded.user_id AND (?16 = 1 OR (workouts.client_updated_at <= excluded.client_updated_at
  AND (workouts.updated_at IS ?17 OR (?17 IS NULL AND workouts.client_updated_at = excluded.client_updated_at))))`

const DELETE_ENTRIES = `DELETE FROM workout_entries WHERE workout_id = ?1 AND ${STILL_THIS_SAVE}`
const INSERT_ENTRIES = `INSERT INTO workout_entries (workout_id, user_id, ${names(ENTRY)})
SELECT ?1, ?3, ${extracted(ENTRY)} FROM json_each(?4) WHERE ${STILL_THIS_SAVE}`
const INSERT_SETS = `INSERT INTO workout_sets (user_id, entry_id, ${names(SET)})
SELECT ?3, json_extract(value, '$.entry_id'), ${extracted(SET)} FROM json_each(?4) WHERE ${STILL_THIS_SAVE}`

export interface WorkoutPushResult {
  readonly status: 'ok' | 'stale'
  readonly updated_at: string
}

interface Parsed {
  readonly workout: Record<string, unknown>
  readonly base: string | null
  readonly force: boolean
  readonly entries: readonly { row: Record<string, unknown>; sets: Record<string, unknown>[] }[]
}

function listOf(raw: unknown, label: string): unknown[] {
  if (raw === undefined || raw === null) return []
  if (!Array.isArray(raw)) throw new RowError(`${label} is not a list`)
  return raw
}

function parseWorkout(body: unknown): Parsed {
  const workout = storedRow(WORKOUT, body, 'workout')
  const pushOnly = storedRow(PUSH_ONLY, body, 'workout')
  const entries = listOf((body as Record<string, unknown>).entries, 'workout.entries').map((raw, i) => {
    const label = `workout.entries[${i}]`
    const row = storedRow(ENTRY, raw, label)
    const sets = listOf((raw as Record<string, unknown>).sets, `${label}.sets`)
      .map((set, j) => storedRow(SET, set, `${label}.sets[${j}]`))
    return { row, sets }
  })
  return { workout, base: pushOnly.base_updated_at as string | null, force: pushOnly.force === 1, entries }
}

/**
 * Saves a workout as upsert_workout did.
 * - `stale`: another device changed it since this edit's version (base_updated_at), unless this is the retry of a save
 *   whose answer was lost; or the server holds a newer edit.
 * - `force` (Keep this iPhone's) overwrites, keeping the later of the two edit times.
 * The row, its entries and its sets change in one batch, and the entries and sets only while the row is still this
 * save's (write_id), so a save that loses a race to another changes nothing and answers `stale`.
 */
export async function pushWorkout(db: D1Database, userId: string, body: unknown): Promise<WorkoutPushResult> {
  const { workout, base, force, entries } = parseWorkout(body)
  const id = workout.id as string
  const incoming = workout.client_updated_at as string
  const existing = await db.prepare('SELECT user_id, client_updated_at, updated_at, gym_id FROM workouts WHERE id = ?1')
    .bind(id).first<{ user_id: string; client_updated_at: string; updated_at: string; gym_id: string | null }>()
  if (existing && existing.user_id !== userId) {
    throw new ApiError(403, 'not_allowed', 'That workout belongs to another account.')
  }
  if (existing && !force) {
    const lostAnswer = base === null && existing.client_updated_at === incoming
    const stale = (existing.updated_at !== base && !lostAnswer) || existing.client_updated_at > incoming
    if (stale) return { status: 'stale', updated_at: existing.updated_at }
  }
  const storedEdit = existing && force && existing.client_updated_at > incoming ? existing.client_updated_at : incoming
  const gymId = await workoutGym(db, userId, existing?.gym_id ?? null, workout.gym_id as string | null)
  const previous = existing ? await previousListings(db, id) : new Map<string, string>()
  const listings = await entryListings(
    db,
    userId,
    entries.map(({ row }) => ({ id: row.id as string, gymEquipmentId: row.gym_equipment_id as string | null })),
    previous,
  )
  const entryRows = entries.map(({ row }) => ({ ...row, gym_equipment_id: listings.get(row.id as string) ?? null }))
  const setRows = entries.flatMap(({ row, sets }) => sets.map((set) => ({ ...set, entry_id: row.id })))
  const writeId = crypto.randomUUID()
  const values = WORKOUT.map((c) => {
    if (c.name === 'client_updated_at') return storedEdit
    if (c.name === 'gym_id') return gymId
    return workout[c.name]
  })
  const results = await db.batch([
    db.prepare(UPSERT).bind(...values, userId, writeId, force ? 1 : 0, base),
    db.prepare(DELETE_ENTRIES).bind(id, writeId),
    db.prepare(INSERT_ENTRIES).bind(id, writeId, userId, JSON.stringify(entryRows)),
    db.prepare(INSERT_SETS).bind(id, writeId, userId, JSON.stringify(setRows)),
    db.prepare('SELECT updated_at, write_id FROM workouts WHERE id = ?1').bind(id),
  ])
  const after = results[4].results[0] as { updated_at: string; write_id: string }
  return { status: after.write_id === writeId ? 'ok' : 'stale', updated_at: after.updated_at }
}

async function previousListings(db: D1Database, workoutId: string): Promise<Map<string, string>> {
  const { results } = await db.prepare(
    'SELECT id, gym_equipment_id FROM workout_entries WHERE workout_id = ?1 AND gym_equipment_id IS NOT NULL',
  ).bind(workoutId).all<{ id: string; gym_equipment_id: string }>()
  return new Map(results.map((r) => [r.id, r.gym_equipment_id]))
}

const WORKOUT_SELECT = `${names(WORKOUT)}, updated_at`

/** One page of the caller's workouts, oldest change first, deleted ones included. `limit` counts workouts. */
export async function pullWorkouts(db: D1Database, userId: string, query: PullQuery) {
  const { results } = await db.prepare(
    `SELECT ${WORKOUT_SELECT} FROM workouts WHERE user_id = ?1 AND ${afterSql('id')} ORDER BY updated_at, id LIMIT ?4`,
  ).bind(userId, query.since, query.after, query.limit).all<Record<string, unknown>>()
  return withEntries(db, results)
}

/** One of the caller's workouts, deleted or not; 404 for a workout that is missing or isn't theirs. */
export async function fetchWorkout(db: D1Database, userId: string, rawId: string) {
  const row = await db.prepare(`SELECT ${WORKOUT_SELECT} FROM workouts WHERE id = ?1 AND user_id = ?2`)
    .bind(rawId.toLowerCase(), userId).first<Record<string, unknown>>()
  if (!row) throw new ApiError(404, 'not_found', 'No such workout.')
  const [workout] = await withEntries(db, [row])
  return workout
}

/** Workouts as the app decodes them, entries[] with sets[] in position order: one query for all entries, one for sets. */
async function withEntries(db: D1Database, workouts: Record<string, unknown>[]) {
  if (workouts.length === 0) return []
  const ids = JSON.stringify(workouts.map((w) => w.id))
  const [entries, sets] = await db.batch<Record<string, unknown>>([
    db.prepare(
      `SELECT workout_id, ${names(ENTRY)} FROM workout_entries WHERE workout_id IN (SELECT value FROM json_each(?1)) ` +
        'ORDER BY position, id',
    ).bind(ids),
    db.prepare(
      `SELECT s.entry_id, ${SET.map((c) => `s.${c.name}`).join(', ')} FROM workout_sets s ` +
        'JOIN workout_entries e ON e.id = s.entry_id WHERE e.workout_id IN (SELECT value FROM json_each(?1)) ' +
        'ORDER BY s.position, s.id',
    ).bind(ids),
  ])
  const setsByEntry = new Map<unknown, Record<string, unknown>[]>()
  for (const { entry_id, ...set } of sets.results) {
    setsByEntry.set(entry_id, [...(setsByEntry.get(entry_id) ?? []), wireRow(SET, set)])
  }
  const entriesByWorkout = new Map<unknown, Record<string, unknown>[]>()
  for (const { workout_id, ...entry } of entries.results) {
    const wired = { ...wireRow(ENTRY, entry), sets: setsByEntry.get(entry.id) ?? [] }
    entriesByWorkout.set(workout_id, [...(entriesByWorkout.get(workout_id) ?? []), wired])
  }
  return workouts.map((w) => ({ ...wireRow(WORKOUT, w), entries: entriesByWorkout.get(w.id) ?? [] }))
}
```

- [ ] **Step 4: Add the routes above `/:entity`**

In `server/src/sync/routes.ts`, import the workouts:

```ts
import { fetchWorkout, pullWorkouts, pushWorkout } from './workouts.ts'
```

and register these three routes directly after `export const syncRoutes = new Hono<AppEnv>()`, before `syncRoutes.post('/:entity', …)`:

```ts
syncRoutes.post('/workouts', async (c) => c.json(await pushWorkout(c.env.DB, c.var.userId, await jsonBody(c))))

syncRoutes.get('/workouts', async (c) => {
  const rows = await pullWorkouts(c.env.DB, c.var.userId, parsePullQuery(c.req.query(), 'text'))
  return c.json({ rows })
})

syncRoutes.get('/workouts/:id', async (c) => c.json(await fetchWorkout(c.env.DB, c.var.userId, c.req.param('id'))))
```

- [ ] **Step 5: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  10 passed (10)`, `Tests  146 passed (146)`.

- [ ] **Step 6: Commit**

```bash
git add server/src/sync server/test/samples.ts server/test/sync-workouts.test.ts
git commit -m "feat(server): workout save, pull and fetch"
```

- [ ] **Step 7: The review follow-ups (added after review)**

The review found the port faithful, and in 20 of 20 runs of two simultaneous saves on one version, one won and one answered `stale`, never mixed. It also found that no index covered a workout's entries or an entry's sets, so every save and pull scanned both tables.

**Index:** `0002_app_schema.sql` gains `workout_entries_workout` and `workout_sets_entry`. The Task 3 SQL block above includes them, and `schema.test.ts` checks them with `EXPLAIN QUERY PLAN`.

**Tests added to `sync-workouts.test.ts`:**
- 10 rounds of two saves at once;
- pulled workouts carry only the app's keys;
- entries and sets come back in position order;
- a deleted workout can still be fetched.

With them: `Tests  151 passed (151)`. Commit: `fix(server): index workout entries and sets; workout race, shape and order tests`.

### Task 9: Deleting an account

`DELETE /v1/account` is `delete_my_account` (`20261030000006_gym_moderation.sql`).
- **Refusal:** it refuses with `photos_remain` while any of the user's gym photos is left. The app removes them first, as today.
- **What stays:** shared gyms and listings, without their author.
- **What goes:**
  - the author's own words: a listing's notes and photo, and report notes,
  - the brand and model of an item only they used,
  - then the account, whose rows cascade.

**Files:**
- Create: `server/src/account/delete.ts`, `server/src/account/routes.ts`
- Modify: `server/src/index.ts`, `server/test/gym-fixtures.ts`
- Test: `server/test/account.test.ts`

- [ ] **Step 1: Write the fixtures and the failing tests**

Append to `server/test/gym-fixtures.ts`:

```ts
/** A photo object the account still owns (plan 28 writes these on upload). */
export async function insertPhoto(owner: string, bucket: 'gym-photos' | 'gym-photos-private' = 'gym-photos-private') {
  const name = `${crypto.randomUUID()}.jpg`
  await env.DB.prepare('INSERT INTO photo_objects (bucket, name, owner_id, created_at) VALUES (?1, ?2, ?3, ?4)')
    .bind(bucket, name, owner, T).run()
  return name
}

/** A confirmation and its count on the listing, as confirm_listing and its trigger left them. */
export async function confirm(listing: string, userId: string) {
  await env.DB.batch([
    env.DB.prepare('INSERT INTO equipment_confirmations (listing_id, user_id, created_at) VALUES (?1, ?2, ?3)')
      .bind(listing, userId, T),
    env.DB.prepare('UPDATE gym_equipment SET confirm_count = confirm_count + 1 WHERE id = ?1').bind(listing),
  ])
}

export async function insertReport(r: {
  reporter: string
  targetType: 'gym' | 'item' | 'listing'
  targetId: string
  note: string
}): Promise<string> {
  const id = crypto.randomUUID()
  await env.DB.prepare(
    "INSERT INTO reports (id, target_type, target_id, reporter_id, reason, note, created_at) VALUES (?1, ?2, ?3, ?4, 'other', ?5, ?6)",
  ).bind(id, r.targetType, r.targetId, r.reporter, r.note, T).run()
  return id
}
```

`server/test/account.test.ts`:

```ts
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import {
  block, confirm, genericItem, insertGym, insertItem, insertListing, insertPhoto, insertReport, makeAdmin,
} from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'
import { SAMPLES, workoutSample } from './samples.ts'

/** Every column that names an account. After the deletion, none may name it. */
const OWNED: readonly [string, string][] = [
  ['"user"', 'id'], ['session', 'userId'], ['account', 'userId'],
  ['profiles', 'user_id'], ['custom_exercises', 'user_id'], ['exercise_prefs', 'user_id'], ['routines', 'user_id'],
  ['week_schedule', 'user_id'], ['muscle_targets', 'user_id'], ['bodyweight', 'user_id'], ['workouts', 'user_id'],
  ['workout_entries', 'user_id'], ['workout_sets', 'user_id'], ['proposals', 'user_id'], ['mcp_audit', 'user_id'],
  ['mcp_calls', 'user_id'], ['photo_objects', 'owner_id'], ['gyms', 'owner_id'], ['gyms', 'created_by'],
  ['gym_equipment', 'owner_id'], ['gym_equipment', 'added_by'], ['equipment_items', 'created_by'],
  ['equipment_confirmations', 'user_id'], ['reports', 'reporter_id'], ['user_blocks', 'blocker_id'],
  ['user_blocks', 'blocked_id'], ['gym_unblocks', 'user_id'], ['app_admins', 'user_id'],
]

async function rowsNaming(table: string, column: string, userId: string): Promise<number> {
  return (await env.DB.prepare(`SELECT count(*) AS n FROM ${table} WHERE ${column} = ?1`).bind(userId)
    .first<{ n: number }>())!.n
}

const row = (sql: string, ...bindings: unknown[]) => env.DB.prepare(sql).bind(...bindings).first<Record<string, unknown>>()

describe('deleting an account', () => {
  it('refuses while any of its gym photos are left, and keeps the account', async () => {
    const { token, userId } = await signUp()
    await insertPhoto(userId)
    const res = await request('DELETE', '/v1/account', { token })
    expect(res.status).toBe(422)
    expect(await res.json()).toEqual({ error: { code: 'photos_remain', message: 'Delete your gym photos first.' } })
    expect((await request('GET', '/v1/sync/profile', { token })).status).toBe(200)
  })

  it("deletes every row of the account and ends its session, and nobody else's", async () => {
    const me = await signUp()
    const other = await signUp()
    for (const [entity, make] of Object.entries(SAMPLES)) {
      const res = await request('POST', `/v1/sync/${entity}`, { token: me.token, body: { rows: [make()] } })
      expect(res.status).toBe(200)
    }
    expect((await request('POST', '/v1/sync/workouts', { token: me.token, body: workoutSample() })).status).toBe(200)
    const gym = await insertGym({ visibility: 'private', owner: me.userId })
    await insertListing({ gym, item: await genericItem(), visibility: 'private', owner: me.userId })
    await makeAdmin(me.userId)
    await block(me.userId, other.userId)
    await block(other.userId, me.userId)
    expect((await request('DELETE', '/v1/account', { token: me.token })).status).toBe(204)
    for (const [table, column] of OWNED) {
      expect(await rowsNaming(table, column, me.userId), `${table}.${column}`).toBe(0)
    }
    expect((await request('GET', '/v1/sync/profile', { token: me.token })).status).toBe(401)
    expect((await request('GET', '/v1/sync/profile', { token: other.token })).status).toBe(200)
  })

  it("keeps shared gyms and listings, without the author or the author's own words", async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const onlyMine = await insertItem({ brand: 'Acme', model: 'X1', createdBy: a.userId })
    const shared = await insertItem({ brand: 'Common', model: 'C1', createdBy: a.userId })
    const photo = `${crypto.randomUUID()}.jpg`
    const myListing = await insertListing({
      gym, item: onlyMine, visibility: 'public', addedBy: a.userId, notes: 'By the window', photo,
    })
    const mySharedListing = await insertListing({ gym, item: shared, visibility: 'public', addedBy: a.userId })
    await insertListing({ gym, item: shared, visibility: 'public', addedBy: b.userId })
    const theirListing = await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: b.userId })
    await confirm(theirListing, a.userId)
    const report = await insertReport({ reporter: a.userId, targetType: 'listing', targetId: theirListing, note: 'Broken' })

    expect((await request('DELETE', '/v1/account', { token: a.token })).status).toBe(204)

    expect(await row('SELECT created_by FROM gyms WHERE id = ?1', gym)).toEqual({ created_by: null })
    expect(await row('SELECT item_id, notes, photo_path, added_by FROM gym_equipment WHERE id = ?1', myListing))
      .toEqual({ item_id: await genericItem(), notes: null, photo_path: null, added_by: null })
    expect(await row('SELECT id FROM equipment_items WHERE id = ?1', onlyMine)).toBeNull()
    expect(await row('SELECT created_by FROM equipment_items WHERE id = ?1', shared)).toEqual({ created_by: null })
    expect(await row('SELECT item_id FROM gym_equipment WHERE id = ?1', mySharedListing)).toEqual({ item_id: shared })
    expect(await row('SELECT confirm_count FROM gym_equipment WHERE id = ?1', theirListing)).toEqual({ confirm_count: 0 })
    expect(await row('SELECT reporter_id, note FROM reports WHERE id = ?1', report))
      .toEqual({ reporter_id: null, note: null })
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/account.test.ts`
Expected: FAIL. `DELETE /v1/account` answers 404 (`No such route.`).

- [ ] **Step 3: Write the deletion**

`server/src/account/delete.ts`:

```ts
import { ApiError } from '../http/errors.ts'
import { NOW_SQL } from '../sync/time.ts'

// Deleting an account, after the app removed its gym photos (delete_my_account,
// supabase/migrations/20261030000006_gym_moderation.sql). Shared gyms and listings stay without their author, because
// they describe the gym, but the author's own words go: a listing's notes and photo, the brand and model of an item
// only they used (their listings fall back to the kind's generic item), and the note on every report they filed. Then
// the account goes, and its rows cascade (D1 enforces the foreign keys).

const photosRemain = () => new ApiError(422, 'photos_remain', 'Delete your gym photos first.')

/** Every statement waits for no photo being left, so one that lands mid-way stops them all. */
const NO_PHOTOS = 'NOT EXISTS (SELECT 1 FROM photo_objects WHERE owner_id = ?1)'

const STEPS = [
  `UPDATE gym_equipment SET photo_path = NULL, notes = NULL, updated_at = ${NOW_SQL}
   WHERE added_by = ?1 AND visibility = 'public' AND ${NO_PHOTOS}`,
  `UPDATE gym_equipment SET updated_at = ${NOW_SQL}, item_id = (SELECT g.id FROM equipment_items g
     WHERE g.kind_id = i.kind_id AND g.brand IS NULL AND g.model IS NULL)
   FROM equipment_items i
   WHERE gym_equipment.item_id = i.id AND i.created_by = ?1 AND (i.brand IS NOT NULL OR i.model IS NOT NULL)
     AND gym_equipment.added_by = ?1 AND gym_equipment.visibility = 'public'
     AND NOT EXISTS (SELECT 1 FROM gym_equipment o WHERE o.item_id = i.id AND o.added_by IS NOT ?1) AND ${NO_PHOTOS}`,
  `DELETE FROM equipment_items WHERE created_by = ?1
     AND NOT EXISTS (SELECT 1 FROM gym_equipment e WHERE e.item_id = equipment_items.id) AND ${NO_PHOTOS}`,
  `UPDATE reports SET note = NULL WHERE reporter_id = ?1 AND ${NO_PHOTOS}`,
  // Postgres recounted confirm_count in a trigger when the confirmations cascaded away; D1 has no such trigger.
  `UPDATE gym_equipment SET updated_at = ${NOW_SQL}, confirm_count = (SELECT count(*) FROM equipment_confirmations c
     WHERE c.listing_id = gym_equipment.id AND c.user_id IS NOT ?1)
   WHERE id IN (SELECT listing_id FROM equipment_confirmations WHERE user_id = ?1) AND ${NO_PHOTOS}`,
  `DELETE FROM "user" WHERE id = ?1 AND ${NO_PHOTOS}`,
]

export async function deleteAccount(db: D1Database, userId: string): Promise<void> {
  if (await db.prepare(`SELECT 1 FROM photo_objects WHERE owner_id = ?1 LIMIT 1`).bind(userId).first()) {
    throw photosRemain()
  }
  await db.batch(STEPS.map((sql) => db.prepare(sql).bind(userId)))
  if (await db.prepare('SELECT 1 FROM "user" WHERE id = ?1').bind(userId).first()) throw photosRemain()
}
```

`server/src/account/routes.ts`:

```ts
import { Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { deleteAccount } from './delete.ts'

/** /v1/account. */
export const accountRoutes = new Hono<AppEnv>()

accountRoutes.delete('/', async (c) => {
  await deleteAccount(c.env.DB, c.var.userId)
  return c.body(null, 204)
})
```

In `server/src/index.ts`, import `accountRoutes` and mount it after the sync routes:

```ts
import { accountRoutes } from './account/routes.ts'
```

```ts
v1.route('/account', accountRoutes)
```

- [ ] **Step 4: Run the tests and the typecheck**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  11 passed (11)`, `Tests  154 passed (154)`. Step 6 brings it to 157.

- [ ] **Step 5: Commit**

```bash
git add server
git commit -m "feat(server): account deletion"
```

- [ ] **Step 6: The review follow-up (added after review)**

The review found every step faithful to `delete_my_account`, and proved three things with probes. These are now permanent tests in `account.test.ts`:
- **A photo appearing after the first check stops the whole batch.** It answers `photos_remain` and nothing changes. The test hides the photo from the first check through a wrapped db.
- **A listing two people confirmed is recounted to 1.**
- **Other people's listings, words and items are left alone.**

With them: `Tests  157 passed (157)`. Commit: `test(server): account deletion stops on a late photo, recounts, and spares others`.

### Task 10: Scripts, README and finish

**Files:**
- Create: `scripts/server-up.sh`, `server/README.md`
- Modify: `scripts/test-all.sh`

- [ ] **Step 1: Write `scripts/server-up.sh`**

```bash
#!/usr/bin/env bash
# The GymRollins API on http://127.0.0.1:8787: the local D1 (server/.wrangler/state) with every migration applied,
# then wrangler dev. Local only: no Cloudflare account is used. Ctrl-C stops it; the local data stays until
# server/.wrangler is removed. The tests never touch it (they use an in-memory D1).
set -euo pipefail
cd "$(dirname "$0")/../server"
if [[ ! -f .dev.vars ]]; then
  echo "Missing server/.dev.vars: copy server/.dev.vars.example and set BETTER_AUTH_SECRET." >&2
  exit 1
fi
[[ -d node_modules ]] || npm ci
npx wrangler d1 migrations apply gymrollins --local < /dev/null
exec npx wrangler dev --local
```

Run: `chmod +x scripts/server-up.sh`

- [ ] **Step 2: Add the server to `scripts/test-all.sh`**

After the MCP block (`echo "==> MCP validator, tools and endpoint …"` and its `deno test` line), add:

```bash
echo "==> API server (Cloudflare Worker: vitest in workerd, in-memory D1)"
(cd "$ROOT/server" && { [[ -d node_modules ]] || npm ci; } && npx vitest run && npx tsc --noEmit)
```

and replace the equipment seed block's comment line with:

```bash
echo "==> Seed generators (node test; drift against the Postgres and D1 migrations)"
```

followed by its two existing lines and this new one:

```bash
node "$ROOT/scripts/gen-exercise-seed.mjs" --check
```

- [ ] **Step 3: Write `server/README.md`**

````markdown
# GymRollins API server

One Cloudflare Worker that replaces Supabase (spec: `docs/specs/2026-11-07-cloudflare-backend-design.md`):

- **Better Auth** at `/api/auth`:
  - Sign in with Apple via the app's id token,
  - bearer session tokens,
  - email and password only when `ALLOW_PASSWORD_AUTH=1`.
- **The app's routes** at `/v1`, all behind the session:
  - `/v1/sync/*` (profile, plan, body weight, workouts),
  - `DELETE /v1/account`.
- **D1** holds the data (`migrations/`). Plans 28 and 29 add R2 photos and the MCP server.

Everything runs locally. Nothing here needs a Cloudflare account until the owner approves a deploy.

```bash
npm ci                         # .npmrc sets legacy-peer-deps
npx vitest run                 # tests in workerd against an in-memory D1 (never the dev data)
npx tsc --noEmit
cp .dev.vars.example .dev.vars # then set BETTER_AUTH_SECRET
../scripts/server-up.sh        # http://127.0.0.1:8787 with a local D1 in .wrangler/state
```

Schema:
- `migrations/0001_better_auth.sql` is generated by `npm run gen:auth-schema`.
- `0002_app_schema.sql` is the Postgres schema translated to SQLite.
- The two seeds come from `scripts/gen-exercise-seed.mjs` and `scripts/gen-equipment-seed.mjs` at the repo root. `--check` there catches drift.
````

- [ ] **Step 4: Check the local server by hand**

Run:

```bash
cp -n server/.dev.vars.example server/.dev.vars
sed -i '' "s/^BETTER_AUTH_SECRET=.*/BETTER_AUTH_SECRET=$(openssl rand -hex 24)/" server/.dev.vars
scripts/server-up.sh
```

This runs in the background (Bash `run_in_background`). It applies 4 migrations (`0001`–`0004` ✅), then serves on `http://127.0.0.1:8787`.

Then:

```bash
curl -s http://127.0.0.1:8787/v1/sync/profile
curl -s -X POST http://127.0.0.1:8787/api/auth/sign-up/email -H 'content-type: application/json' \
  -d '{"email":"dev@test.local","password":"correct-horse-battery","name":"Dev"}' -o /dev/null -w '%{http_code}\n'
```

Expected:
- `{"error":{"code":"signed_out","message":"Sign in required."}}`
- `200`

Stop the server with `pkill -f "wrangler dev --local"`. Never print `server/.dev.vars`. Never commit it: `git status` must not list it.

- [ ] **Step 5: Run everything this plan touched**

Run:

```bash
(cd server && npx vitest run && npx tsc --noEmit)
node --test scripts/gen-equipment-seed.test.mjs
node scripts/gen-exercise-seed.mjs --check && node scripts/gen-equipment-seed.mjs --check
(cd supabase/functions && deno test --allow-read _shared/ mcp/)
```

Expected:
- `Test Files  11 passed (11)`, `Tests  157 passed (157)`.
- The seed tests: `# pass 5`, and both checks match.
- The Deno suite is unchanged: `159 passed … 1 ignored`. This plan doesn't touch it.

- [ ] **Step 6: Commit**

```bash
git add scripts/server-up.sh scripts/test-all.sh server/README.md
git commit -m "chore(server): local server script, test-all and README"
```

- [ ] **Step 7: Review and outcome**

1. Have a separate reviewer read the whole diff: `git diff feat-claude-prompts...HEAD -- server scripts .gitignore`. Use the `code-reviewer` agent plus a TypeScript reviewer, and the `security-reviewer` for `src/auth`, `src/sync/table-sync.ts` and `src/account`.
2. Fix CRITICAL and HIGH findings in their own commits, and re-run Step 5.
3. Append `## Outcome` to this plan:
   - the commits,
   - the final test counts,
   - every place the build differed from this plan,
   - what wasn't run.

   Commit it as `docs: plan 26 outcome`.

## Outcome

Built on 2026-11-07, on `feat-cloudflare`. Local only, not pushed, and no Cloudflare account was used. Each task was built by a fresh subagent, then reviewed: spec compliance first, then quality, and security for auth, sync and account.

**Commits** (code; each `docs:` commit kept this plan in step with what was built)

| Task | Commits |
|---|---|
| 1 Worker skeleton | `a9be198` |
| 2 Sign-in | `993266f`, review fix `845e61f` |
| 3 Schema and seeds | `7715d4b`, D1 pattern-limit fix `7b25a22` |
| 4 Time and columns | `5e17843`, review fix `7baec99` |
| 5 Row sync | `b3ffd52`, review follow-ups `386b81a` |
| 6 Apple Health rules | `7c8c5be` |
| 7 Gym links | `96dc2d3`, coverage tests `43cdd4c` |
| 8 Workouts | `bbfc0b4`, indexes and tests `9d84af3` |
| 9 Account deletion | `b1c4140`, safety tests `ceccf54` |
| 10 Scripts and README | `67e1d49` |
| Final review | `a79a8ee` |

**Final counts**
- Server: `Test Files  11 passed (11)`, `Tests  160 passed (160)`, and `tsc --noEmit` clean.
- Seed generator tests: `# pass 5`, and both `--check` runs match.
- The Supabase Deno suite is unchanged: `159 passed | 1 ignored`.
- **Checked by hand:**
  - `scripts/server-up.sh` applied migrations 0001–0004 to the local D1, answered `signed_out` JSON and took a sign-up.
  - It refuses the example secret.

**Where the build differs from the plan as first written.** Each difference is also recorded in its task.

1. **Sign-in is deny-by-default (Task 2, step 7).**
   - Better Auth checks an id token's nonce only when the client sends one. Without an id token, it starts a web redirect flow.
   - `src/auth/routes.ts` lets five routes through and requires the token and a nonce.
2. **D1 refuses LIKE and GLOB patterns over 50 bytes** (measured in workerd). The `sqlite3` CLI doesn't, unless `.limit like_pattern_length 50` is set.
   - The timestamp and photo-name CHECKs are split into pieces of at most 48 bytes.
   - A test scans every migration (Task 3, step 8).
3. **Values (Task 4):**
   - Dates must be real calendar days.
   - Years before 100 parse as the app does: `setUTCFullYear`, not `Date.UTC`.
   - `int` needs a safe integer.
4. **Row sync (Task 5, step 8):**
   - An empty `after` is refused.
   - The body limit is 1 MiB, because one bound JSON value must stay under D1's ~2 MB.
   - A test proves the upsert's own owner `WHERE` holds without the 403 pre-check.
5. **Workouts (Task 8, step 7):**
   - Two indexes were added: `workout_entries(workout_id)` and `workout_sets(entry_id)`.
   - 10 rounds of two simultaneous saves each give one `ok` and one `stale`, never mixed.
6. **Final review (`a79a8ee`):**
   - A 16 KB body limit on `/api/auth/*`.
   - Better Auth's errors come back in the API's `{"error": {code, message}}` shape, with lowercase codes such as `invalid_token` and `user_already_exists_use_another_email`.
   - `/v1` accepts only `Authorization: Bearer`, never the session cookie.
   - `server-up.sh` refuses the placeholder secret.
7. **Extra tests from the reviews:**
   - every gym and listing visibility rule (Task 7, step 7);
   - account deletion stopping on a photo that appears mid-way, recounting a listing two people confirmed, and sparing other people's rows (Task 9, step 6).

**Passed to later plans**
- **Plan 27, iOS:**
  - Map Better Auth's lowercase error codes in `AuthFailure`.
  - Pull workouts with a smaller page than 500, because each page carries every entry and set.
  - Send only `Authorization: Bearer`.
- **Plan 28, gyms and photos:**
  - `Entity` needs a pull scope and an owner column for gyms and listings.
  - Give the visibility fragments a parameter for the caller rather than the fixed `?2`.
  - Move the `json_extract` and column-list helpers that `table-sync.ts` and `workouts.ts` share into one module.
  - SQLite's `lower()` folds ASCII only, so normalise brand and model in TypeScript.
  - Store `loads` as compact JSON.
  - Port `clean_text`'s invisible-character rules to TypeScript.
  - R2 and D1 share no transaction: write a pending `photo_objects` row first.
- **Plan 29, Claude:**
  - Add the OAuth routes to the auth allowlist.
  - Exercise search builds LIKE patterns from Claude's words, so keep them under D1's 50 bytes, or use `instr()`.
  - Put the D1 `Db` beside the MCP code.

**Before any deploy** (from the security review; for the Cloudflare checklist in plan 30)
- **Config:**
  - The real `database_id`.
  - `PUBLIC_BASE_URL` set to the https origin.
  - `wrangler secret put BETTER_AUTH_SECRET` with 32 or more random bytes.
  - `ALLOW_PASSWORD_AUTH` staying `0`, with no dashboard override.
- **Rate limits:** a Cloudflare rate-limit rule (or binding) on `/api/auth/*` and `/v1/*`. Better Auth's built-in limiter is per isolate, and is off unless NODE_ENV is production.
- **Usage:** per-user row caps, plus spend and usage alerts.
- **Dependencies:** `npm audit`, and `npm ci` in CI, because of `legacy-peer-deps`.
- **Data safety:**
  - D1 Time Travel backups.
  - Back up the phone before the cutover.

**Not run**
- Nothing ran against a deployed Worker, and claude.ai wasn't involved: that's plan 29 and the deploy.
- No iOS code changed, so `scripts/test-all.sh` wasn't run in full. Its iOS suites take long and nothing they test changed. Its server and seed steps ran on their own (above).
- Apple sign-in was tested only with locally signed tokens against a mocked key URL. A real Apple token is first used in plan 27.
