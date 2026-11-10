# Cloudflare backend: design spec

Date: 2026-11-07 · Status: design approved by the owner on 2026-11-07, section by section; written spec awaiting review.
Builds on: the unmerged branch `feat-claude-prompts` (plan 25), which sits on plans 19 to 24.

## 1. Goal

GymRollins stops depending on Supabase. One Cloudflare Worker serves everything the app and Claude use today:
- **Sign-in** with Better Auth.
- **Data** in D1.
- **Photos** in R2.
- **Claude's MCP server and its OAuth login,** with Better Auth's plugins.

Local development needs no Docker. The owner's phone moves its data to the new server in its first sync, without a wipe.

### Acceptance criteria

1. **No Supabase.**
   - The repo has no `supabase/` folder, no `supabase-swift` dependency and no script that starts Docker.
   - The app, the tests and the docs name `API_URL` and the Worker only.
2. **Same behaviour.** Everything the app and Claude can do on the Supabase branch works the same against the Worker:
   - sync and conflicts,
   - the gym catalogue, sharing, photos and moderation,
   - proposals and Claude's 15 tools,
   - permissions, the daily limits and caps,
   - account deletion.
   The app shows the same messages, because the error codes keep their strings.
3. **Isolation.**
   - No account can read or change another account's rows.
   - A Claude token works only on `/mcp`, and an app session works only on `/api` and `/v1`.
   - Claude reads only what the Settings › Claude toggles allow, and writes only proposals and body weight.
4. **Sign in with Apple.**
   - The app signs in with the Apple token it already gets. There's no web flow and no extra Apple setup.
   - Email and password exist in debug builds only, for tests.
5. **Approve in the app.**
   - Claude's sign-in page shows a code, and the owner approves it in Settings › Claude › **Approve a connection**.
   - Codes expire in 10 minutes and work once. Only the browser that showed the code can continue.
6. **Disconnect.** **Disconnect Claude** removes all of Claude's grants and tokens, and Claude's next call is refused.
7. **Server move.**
   - When the server changes, the app's next launch hands the local data to the next account that signs in and marks every record unsynced.
   - It deletes nothing.
   - With a copy of the owner's phone data on the simulator, all 148 workouts, 836 entries and 2,685 sets reach the local Worker.
8. **Free plan.** Nothing needs a paid Cloudflare plan, KV or Durable Objects.
9. **Local only.** No Cloudflare account, resource or deploy is created during this work.
   - Deploying, pointing the phone at it and connecting claude.ai are separate steps, each approved by the owner (section 9).

### Out of scope

- **No new features.** Behaviour stays as section 4 describes.
- **No changes** to the Watch app, HealthKit or the SwiftData models.
- **No realtime.** The app polls, as now.
- **No web sign-in for people.** Only Claude's approval page exists on the web.
- **No moving the old Supabase data.** The local server holds nothing of value, and the phone has the only live copy.
- **No custom domain.** The free `workers.dev` address is used until the owner asks for one.

## 2. Decisions (settled in brainstorming, 2026-11-07)

| Question | Decision |
|---|---|
| Why move | One platform (the owner's other projects run on Cloudflare), lower cost (free tier), simpler to run (no Docker). Cloudflare + Better Auth became the owner's default stack for new projects the same day. |
| Auth library | **Better Auth** for both app sign-in and Claude's OAuth. The owner first named OpenAuth. The package was checked and rejected: `@openauthjs/openauth` 0.4.3 (last release March 2025, pre-1.0) takes only the `authorization_code`, `refresh_token` and `client_credentials` grants. So it can't take the native Apple token, and it has no client registration endpoint, which Claude's connectors need. Better Auth 1.7.18 (released 2026-11-05) verifies native Apple id tokens (`appBundleIdentifier`). It ships a D1 dialect, and its `oauth-provider` plugin serves dynamic registration, client metadata documents and protected-resource metadata. Cloudflare's `workers-oauth-provider` would also work, but it keeps grants in KV beside a second auth system. |
| Build order | **All at once.** One spec, five plans built back to back on one branch, and a single cutover at the end. Each plan still ends with its own passing tests. |
| Claude's sign-in page | **Approve in the app.** The page shows a code, and the owner types it into the signed-in app. This avoids Sign in with Apple on the web, which needs a Services ID and a secret renewed every 6 months, and email, which needs a mail service. |
| Query layer | Plain SQL through D1 prepared statements, one module per area, no ORM. Better Auth uses its built-in D1 support for its own tables. |
| Rules that were RLS | One rule in code: the user id comes only from the verified session or token, and every query filters by it. App and Claude requests go through separate handlers. |
| Locks and limits | D1 runs writes one at a time, so each limit is one conditional statement ("insert only if the count is under the limit") or one batch. Batches run as a transaction. There are no locks and no Durable Objects. |
| The phone's data | The phone's records are all marked synced to the old server: 148 of 148 workouts, with owner id and sync markers set. A one-time server move in the app makes them upload to the new one (section 4). |
| Where it runs while building | `wrangler dev` with local D1 and R2. Deploying waits for the owner, as the Supabase cloud project did. |

## 3. Architecture

```
iPhone app ──(session token)──▶ /api/auth/*   Better Auth (Apple id token, sessions, debug email)
           ──(session token)──▶ /v1/*         sync, gyms, photos, moderation, Claude settings, account
Claude     ──(OAuth token)────▶ /mcp          MCP server (createMcpHandler + McpServer, the 15 tools)
           ──(browser)────────▶ /api/auth/oauth2/*, /connect, /.well-known/*
Public     ───────────────────▶ /photos/shared/*, /photos/exercises/*   (R2, cached)
                                        │
                     one Worker (Hono, TypeScript) ── D1 `gymrollins` · R2 ×3
```

**Repo layout**
- **`server/`:**
  - `wrangler.jsonc`, `package.json`, `migrations/` (D1 SQL),
  - `src/app.ts` (Hono routes), `src/auth/` (Better Auth config and the connect flow),
  - `src/sync/`, `src/gyms/`, `src/photos/`, `src/moderation/`, `src/claude/` (the app's `/v1` routes),
  - `src/mcp/` (the MCP server, moved from `supabase/functions/mcp`),
  - `src/shared/` (moved from `supabase/functions/_shared`),
  - `test/`.
- **`ios/Packages/GymSync`:**
  - `ApiClient` (URLSession, JSON and errors), `ApiSyncTransport` and `ApiGymCatalogTransport` behind the existing protocols, and `AuthService` with a Keychain session.
  - The `Supabase*` files and the `supabase-swift` dependency are removed.

**Storage**
- **D1 database `gymrollins`:**
  - The 24 app tables, with the same names, columns and CHECK constraints.
  - Better Auth's tables: `user`, `session`, `account`, `verification`, and the oauth-provider tables.
  - `connect_requests` for the approval codes.
  - `photo_objects`, which takes the place of `storage.objects`: bucket, name, owner, created_at.
- **R2 buckets:**
  - `gym-photos`: public read through the Worker.
  - `gym-photos-private`: only through `/v1`, owner only.
  - `exercise-photos`: public; holds the photos and `manifest.json`.

**Type mapping (Postgres → D1)**
- `uuid` becomes lowercase text.
- `timestamptz` becomes text in one fixed UTC format, `YYYY-MM-DDTHH:MM:SS.ffffffZ`. The server normalises every timestamp before storing it, so text order is time order and last-write-wins compares like for like.
- `jsonb`, `text[]` and `numeric[]` become JSON text, with a `json_valid` CHECK.
- `bigint identity` becomes `INTEGER PRIMARY KEY`.
- `numeric` becomes `REAL`.
- Foreign keys and their `ON DELETE` rules stay; D1 enforces them. `auth.users` becomes Better Auth's `user` table, whose ids are set to UUIDs.

**Routes (`/v1`, app session only)**

| Area | Routes | Replaces |
|---|---|---|
| Sync | `POST /v1/sync/:entity` (rows → acks), `GET /v1/sync/:entity?since&after&limit` (keyset pages of 500), `POST /v1/sync/workouts` (`upsert_workout` rules), `GET /v1/sync/workouts[/:id]` (with entries and sets nested) | PostgREST upserts and selects, `upsert_workout` |
| Gyms | `GET /v1/gyms/public?place=`, `GET /v1/gyms/:id/listings`, `GET /v1/items?kind=`, `POST /v1/gyms/find-or-create`, `POST /v1/listings/share`, `POST /v1/listings/:id/confirm` | the `public_*` views, `find_or_create_gym`, `share_listing`, `confirm_listing` |
| Moderation | `POST /v1/reports`, `POST /v1/blocks`, `DELETE /v1/blocks`, `GET /v1/admin/me`, `GET /v1/admin/queue`, `POST /v1/admin/moderate`, `POST /v1/admin/photo-deleted` | `report_content`, `block_author`, `unblock_all`, `is_app_admin`, `moderation_queue`, `moderate_content`, `moderation_photo_deleted` |
| Photos | `PUT`, `GET` and `DELETE /v1/photos/private/:name`; `PUT` and `DELETE /v1/photos/shared/:name` (owner, or an admin deleting a removed listing's photo); `GET /v1/photos/mine`; `POST /v1/photos/detach` | Storage, `my_gym_photos`, `detach_my_gym_photos`, the photo guard trigger |
| Claude | `GET /v1/claude/proposals`, `PATCH /v1/claude/proposals/:id`, `GET /v1/claude/last-use`, `GET /v1/claude/connect/:code`, `POST /v1/claude/connect/:code`, `POST /v1/claude/revoke` | `proposals` and `mcp_audit` selects, the consent page, the grant list and revoke |
| Account | `DELETE /v1/account` | `delete_my_account` |

The exact request and response bodies are fixed in the plans. They carry the same DTO fields the app sends and decodes today.

## 4. Key behaviours

### Sync (unchanged contract)
- **Push** returns one ack `{id, updated_at}` for each row stored. A row refused by last-write-wins gets no ack and stays dirty, as with `lww_guard` today. Its stored `client_updated_at` is newer.
  - The guard is the upsert's own condition: `ON CONFLICT DO UPDATE ... WHERE excluded.client_updated_at >= stored.client_updated_at`.
  - The server stamps `updated_at`.
- **Bodyweight** keeps its Health tombstone rules: a row deleted in Health stays deleted, and a Health deletion wins over an older live edit.
- **Workouts** keep `upsert_workout`'s rules exactly: `base_updated_at`, the retry of a lost ack, the `stale` answer, `force`, and keeping a gym link that is still valid. Entries and sets are replaced in the same batch.
- **Pull** pages by `(updated_at, tiebreak)` with the same tiebreak column per table, and returns tombstones.
- **Requests stay under D1's limits:** at most 100 bound values per statement, and at most 50 statements per request on the free plan. Multi-row statements are split into chunks.

### Permissions and Claude
- **Claude's handler** has a read-only `Db`, plus `insertProposal` and `insertBodyweight`. Before each read it checks the matching toggle (`mcp_read_plan`, `_workouts`, `_body`, `_gyms`) in TypeScript, as `mcp_flag` did.
  - `never_exercise_ids` still answers when the plan toggle is off and propose is on.
- **The rate limit** is 60 calls per user per rolling minute, done in one statement that inserts a call only if the last minute holds fewer than 60.
- **Every tool call** writes an audit row, as today.

### Gyms, photos and moderation
- **Every limit in `_shared/domain-limits.ts` keeps its number and its error code.** The limits run over a rolling 24 hours, per user:
  - 10 new public gyms, 30 shared listings, 100 confirmations,
  - 60 photo uploads (deleting a photo frees a slot),
  - 20 reports, 20 new blocks, 3 unblock-alls.
- **The caps:** 100 private gyms and 1,000 private listings per user, and 300 active public listings per gym.
- **Moderation rules:**
  - 3 unresolved reports from existing accounts flag a target.
  - Reporting your own content answers `own`, and a second report of the same target answers `already`.
  - A share of a kind that already exists at that gym answers `duplicates` unless forced.
- **Photos:**
  - A photo upload is checked before the object is written:
    - the name format,
    - JPEG only, at most 1 MB,
    - the owner exists,
    - the name isn't used yet,
    - fewer than 60 uploads today, counted in `photo_objects`.
  - The object and its `photo_objects` row are written together; if the row fails, the object is deleted.
  - Duplicate uploads answer 409, which the app already treats as success.

### Sign-in
- **Apple:** `POST /api/auth/sign-in/social` with `{provider: "apple", idToken: {token, nonce}}`.
  - The audience is the app's bundle id.
  - Which nonce form Better Auth checks, raw or SHA-256, is confirmed in plan 26 against the app's `AppleNonce`.
- **Sessions:**
  - Better Auth's bearer plugin returns a session token, which the app keeps in the Keychain.
  - A session lasts 60 days and renews when it's used.
  - A 401 means signed out, and local data stays.
- **Delete account:** photos first, as today; then `DELETE /v1/account` refuses with `photos_remain` while any `photo_objects` row is left.
  - It then scrubs shared text as `delete_my_account` does, and deletes the user. D1's foreign keys cascade.

### Claude's connection
1. Claude reads `/.well-known/oauth-protected-resource` (from the 401 on `/mcp`) and `/.well-known/oauth-authorization-server`.
2. It registers itself, dynamically or with a client metadata document. It then opens `/api/auth/oauth2/authorize` with PKCE.
3. **The sign-in page.** Better Auth's login step sends the browser to `/connect`, which:
   - stores a `connect_requests` row: a code of 8 characters from a 32-letter alphabet, with a hash of a secret cookie set on that browser, the client, its redirect host, a 10-minute expiry and status `waiting`,
   - shows the code and which Claude is asking.
4. **The app:**
   - The owner opens **Approve a connection** and types the code. `GET /v1/claude/connect/:code` returns the client name and the redirect host; a host that isn't claude.ai or claude.com gets a warning.
   - **Approve** or **Deny** posts the decision.
   - Each account gets 5 wrong codes per 10 minutes.
5. **Continuing.** The page checks every 2 seconds. When the request is approved and the browser's cookie matches, the Worker:
   - gives that browser a Better Auth session for the owner,
   - marks Claude's consent as given,
   - continues the authorize step, which redirects back to Claude with the code.
   A denied request returns `access_denied`. Any second use of a code fails.
6. **Tokens.**
   - Refresh tokens rotate.
   - Access tokens are checked against D1 on every `/mcp` call, so `POST /v1/claude/revoke` (Disconnect Claude) stops access at once.
   - The redirect URLs allowed are `https://claude.ai/api/mcp/auth_callback`, `https://claude.com/api/mcp/auth_callback` and `http://localhost` / `127.0.0.1` with any port, for Claude Code.

### Server move (app)
- **What the app records.**
  - It stores the API host its data last synced with, under `gymrollins.sync.server`.
  - At launch, if records exist with an owner or sync markers, and the stored host is missing or differs from `API_URL`, the app runs the move once.
- **The move:**
  1. Clear the owner id.
  2. Clear every pull cursor.
  3. Clear `serverUpdatedAt` and set `dirty` on every synced record, including private gyms, listings and their photo markers.
  4. Drop cached pending proposals.
  5. Store the new host.
- **What happens next.**
  - The next sign-in adopts the data (the owner is nil).
  - The first sync uploads everything, and workouts go up with no base version, so they're stored as new.
  - "This phone only" gyms and unsynced edits are untouched. Nothing is deleted.

## 5. UI

- **Settings › Claude** gains a row, **Approve a connection**, that opens a sheet with:
  - a code field (8 characters, shown as `XXXX-XXXX`, case-insensitive),
  - then the asking client's name and redirect host, with the warning when the host isn't Claude's,
  - then **Approve** and **Deny**.
  - Each sits on its own row, because a Form row fires every button it holds.
- **The `/connect` page** shows:
  - the code in large type, and "Open GymRollins › Settings › Claude › Approve a connection and type this code",
  - which Claude is asking,
  - a countdown, and "Approved, returning to Claude…" or "Denied".
  - It's plain HTML from the Worker, with a strict Content-Security-Policy and no third-party scripts.
- **Nothing else changes on screen.** The connector address shown in Settings › Claude becomes `<API_URL>/mcp`.

## 6. Error handling

- **Every error body** is `{"error": {"code": "...", "message": "..."}}`. The codes keep today's strings:
  - `photos_remain`, `daily_limit`,
  - `too_many_gyms`, `too_many_listings`, `gym_full`, `gym_not_shareable`,
  - `photo_missing`, `photo_in_use`, `photo_daily_limit`, `photo_name_in_use`, `photo_bad_name`, `photo_not_jpeg`, `photo_owner_missing`,
  - `place_taken`, `unknown_target`, `not_allowed`, `row_rejected`.
- **HTTP statuses:**
  - 401 signed out,
  - 403 not allowed,
  - 404 not found,
  - 409 duplicate,
  - 422 refused row or rule (with the code),
  - 429 too many requests (Claude's call limit),
  - 5xx server.
- **The app's three mappers** (`GymCatalogErrors.map`, `AuthFailure`, `mappingRejections`) read `ApiError`.
  - They match the code first, then the status.
  - The offline cases stay: network errors, 5xx and 429.
- **Claude's tool errors** keep `ToolError`: a refused permission reads "Not allowed", as now.

## 7. Security and privacy

- **No secrets in the repo.** `BETTER_AUTH_SECRET` and any keys live in the gitignored `server/.dev.vars` locally, and in `wrangler secret` once deployed. The Apple bundle id isn't a secret.
- **Every query filters by the authenticated user id.** No route takes a user id from the request body or the URL.
- **The two token kinds are refused outside their routes.** Admin routes also require an `app_admins` row and an app session.
- **Shared text keeps the `clean_text` checks** on gym names, addresses, notes and report notes: no control, invisible, bidi, tag or private-use characters. Listing loads keep their JSON shape check.
- **Photos:**
  - Private photos are served only to their owner, with `Cache-Control: private, no-store`.
  - The app keeps its URL cache off for them.
  - Public photos carry no user ids in their names.
- **Approval codes:**
  - The code is shown only on the page that asked. Its browser secret is stored hashed. Codes expire, work once, and are limited per account.
  - The page never shows account data.
- **The owner's personal data stays out of the repo.** Test data is synthetic, and the server-move test uses a copy of the phone's store kept in the scratchpad, never committed.
- **CORS** is open only on `/mcp` and the metadata routes, as now.

## 8. Testing

**Server (`server/`, Vitest with `@cloudflare/vitest-pool-workers`, real local D1 and R2)**
- **Moved:**
  - the 127 MCP tests (fake `Db`), switched from `Deno.test` to Vitest with the same assertions,
  - the shared validation, insights and strength tests,
  - the limits drift test (Swift, TypeScript and SQL).
- **New, replacing the 18 pgTAP files:**
  - **For every table:** account B can't read, change or delete account A's rows.
  - **Tokens:**
    - a Claude token is refused on `/v1` and `/api`,
    - an app session is refused on `/mcp`.
  - **Claude's reads and writes:**
    - each toggle hides exactly its data from Claude,
    - Claude can only insert pending proposals and body weight.
  - **Sync:**
    - last-write-wins on every synced table,
    - every `upsert_workout` case, including retry, stale, force and gym links,
    - the Health tombstone rules.
  - **Limits:**
    - every daily limit and cap at its exact number,
    - 70 concurrent Claude calls give exactly 60 successes.
  - **Photos and account deletion:**
    - every photo refusal,
    - account deletion refusing with `photos_remain`, then leaving zero rows for that user while shared gyms stay, with authors cleared.
  - **The connection:**
    - registration, the authorize redirect to `/connect`,
    - the code from the app (approve, deny, expiry, reuse, 5 wrong tries, a different browser),
    - then the token, a tool call, refresh, revoke and the 401.
- **Tests run on their own local state folder,** never the development one.

**iOS**
- **GymSync unit tests:**
  - The tests that build `PostgrestError` or `AuthError` now build `ApiError`.
  - New tests: `ApiClient` (with a URLProtocol stub), `AuthService` sign-in, restore and sign-out, and the server move.
- **GymSyncIntegrationTests and the sync UI tests** run against `wrangler dev`, with the same suites.
- **The server-move check:**
  1. A copy of the owner's phone store goes into the simulator.
  2. The app signs in to the local Worker.
  3. D1's counts must match (148 workouts, 836 entries, 2,685 sets, 6 routines, 24 body weights), and the phone's records must be unchanged apart from sync state.
- **Claude Code** connects to the local `/mcp` as a real client through the approval flow. claude.ai is checked only after the deploy (section 9).

## 9. Milestones

Plans live in `docs/plans/`. They're built in order on branch `feat-cloudflare` (from `feat-claude-prompts`), and nothing is pushed.

| Plan | Delivers |
|---|---|
| 26: Server and sync | `server/` with Hono, D1 migrations (the tables, seeds, Better Auth and the new tables), Better Auth sign-in, `/v1/sync/*` and `/v1/account`, plus the isolation and sync tests. |
| 27: App client and server move | `ApiClient`, `ApiSyncTransport`, `AuthService` on Better Auth, `API_URL` config, the server move, and the integration suites on `wrangler dev`. |
| 28: Gyms, photos and moderation | R2 buckets, `photo_objects`, `/v1/gyms`, `/v1/listings`, `/v1/photos`, `/v1/reports`, `/v1/blocks` and `/v1/admin`, plus `ApiGymCatalogTransport`. |
| 29: Claude | The MCP server on the Worker with a D1 `Db`, Better Auth OAuth provider and MCP plugins, `/connect`, **Approve a connection**, revoke, and the connection test with Claude Code. |
| 30: Remove Supabase | Delete `supabase/`, `web/consent/`, the Supabase scripts and `supabase-swift`. Rewrite the README and docs. Add a Cloudflare checklist in place of `cloud-checklist.md`. |

**After plan 30, each step is approved by the owner separately:**
1. Create the Worker, D1 and the three R2 buckets, and deploy.
2. Set `API_URL` in `Local.xcconfig`.
3. Back up the phone, install, sign in, and check that the server's counts match the phone's.
4. Connect Claude on claude.ai.

Stopping this project's Supabase containers is a separate question for the owner. Other projects' containers are never touched.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Better Auth's Apple id token check expects a different nonce form than the app sends | Plan 26 checks it against `AppleNonce` and Better Auth's source, and fixes the app side if needed. |
| Better Auth's login step can't hand the browser to `/connect` and back as section 4 says | Plan 29 builds the connect flow first, behind a test of the whole flow. If the plugin's login hook isn't enough, `/connect` signs the browser in with Better Auth's server API and re-enters the authorize URL. |
| OAuth access tokens are JWTs that can't be revoked at once | Configure opaque tokens checked in D1, or check each token's grant in D1 on every call. Verified in plan 29. |
| D1 batch transaction semantics are documented ambiguously | Rules that must be atomic are single statements where possible. Batch rollback is covered by a test that forces a failing statement. |
| D1 free-plan limits: 50 statements per request, 100 bound values, 100,000 rows written a day | Chunked statements, and a test that the full upload of the owner's data stays under them. The first upload is about 3,700 rows. |
| The server move runs when it shouldn't, or misses records | It runs only on a host change. It's tested with a copy of the real store, and the phone is backed up before install. |
| `@cloudflare/vitest-pool-workers` and local D1/R2 behave differently from production | Keep the tests on public APIs. The deploy step (section 9) re-runs the connection and sync checks against the deployed Worker. |
| Claude's connector needs differ from the docs | The 401 metadata, registration, PKCE and refresh rotation follow claude.com's connector docs (checked 2026-11-07). The claude.ai check after the deploy is the final test. |
