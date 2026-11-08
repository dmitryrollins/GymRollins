# Cloudflare deploy checklist

Everything in this repo runs locally: `scripts/server-up.sh` serves the Worker on `http://127.0.0.1:8787` with a local
D1 and R2, and the tests start throwaway Workers of their own. Nothing has been created on Cloudflare.

This list is the owner's. **Every step below touches the Cloudflare account, the owner's phone or claude.ai, so each
one runs only with the owner's approval, given for that step** (spec `docs/specs/2026-11-07-cloudflare-backend-design.md`,
section 9). Work through it in order: the rate limits come before anything else.

**The account.** GymRollins lives on the **VIPPIE LLC** Cloudflare account. Wrangler sees five accounts on this Mac,
so every `wrangler` command against it, the scripts' included, runs with
`CLOUDFLARE_ACCOUNT_ID=<account-id>` (an account id, not a secret): `export` it in the shell first,
as section 2 does.

`<origin>` below is the Worker's https address: `https://api.gymrollins.com`, the custom domain the owner chose
(section 1, option A).

## 0. Before anything is created (local)

- [ ] `scripts/test-all.sh` passes on the branch being deployed, with `SYNC_E2E=1 MCP_E2E=1 PHOTO_E2E=1 GYM_E2E=1`.
- [ ] `cd server && npm ci && npm audit`. Fix every high and critical finding first.
- [ ] Deploy only from a tree that `npm ci` built: `server/.npmrc` sets `legacy-peer-deps`, so `npm install` can
      resolve a different tree than the one the tests ran on. Any CI that builds the server runs `npm ci` too.
- [ ] The manual Claude Code connection has been tried against the local Worker: `server/README.md`, "Claude", the
      paragraph "The manual step for the owner". It is interactive, so only the owner can do it; the scripted
      `node scripts/claude-local.mjs smoke` stands in for it in the tests.
- [ ] The decisions in sections 1 and 5 are made, and any code they need is built and tested locally in a plan of
      its own.

## 1. Rate limits, before anything else (owner's approval)

Why first:
- Better Auth's own limiter counts per isolate, and is off unless `NODE_ENV` is production.
- The OAuth registration cap (30 new clients an hour) is global. Anyone can use it up and keep Claude from
  registering.
- `/connect` is public (20 sign-ins per client per 10 minutes).

The Worker's own caps are not per IP: the registration cap is global, `/connect`'s 20 sign-ins are per client (anyone can
register more clients), and `/mcp`'s 60 calls a minute are per account (a refused token still costs a D1 lookup). So
every one of these paths gets a per-IP rule from Cloudflare, before anything else is done:
- `/api/auth/*`: sign-in, authorize and token,
- `/api/auth/oauth2/register`: dynamic client registration, with the tightest limit,
- `/connect`: Claude's sign-in page,
- `/v1/*`: the app's reads and pushes,
- `/mcp`: Claude's calls (the Worker already allows 60 a minute per account).

**The owner chose A, a custom domain** (2026-11-08): the Worker answers on `https://api.gymrollins.com`, with the
per-IP rules below. Cloudflare's rate-limiting rules belong to a zone, which is a domain on the account. The free
`*.workers.dev` address isn't one, so no rule can be put on it. The two options were:
- **A. A custom domain.**
  - Add the domain to the account, route the Worker to `api.gymrollins.com` (`routes` in `server/wrangler.jsonc`),
    and set `"workers_dev": false`.
  - Add rate-limiting rules (Security › WAF › Rate limiting rules), counted per IP:
    - one for registration, with a low limit: `(http.request.uri.path eq "/api/auth/oauth2/register")`
    - one for the rest, with this expression:
      `(starts_with(http.request.uri.path, "/api/auth/") or starts_with(http.request.uri.path, "/connect") or starts_with(http.request.uri.path, "/v1/") or starts_with(http.request.uri.path, "/mcp"))`
  - Check the free plan's limits for these rules on that page (how many rules, which time windows). If it allows one
    rule only, use the one for the rest and let the registration path share it.
  - `<origin>` is then the custom domain, `https://api.gymrollins.com`.
- **B. Stay on `workers.dev`, and limit inside the Worker** with Workers' rate-limiting binding.
  - That is a code change: a plan of its own, tested locally like plans 26–29, before step 2.
  - Check that the binding is available on the free plan, and that its limits (a fixed window per binding, counted
    per Cloudflare location) are enough for the registration path.
  - Not taken: the owner chose A.

## 2. Create the resources (owner's approval)

```bash
cd server
export CLOUDFLARE_ACCOUNT_ID=<account-id>   # VIPPIE LLC (the top of this list)
npx wrangler login                                  # the owner's Cloudflare account, in the browser
npx wrangler d1 create gymrollins                   # prints the database_id
npx wrangler r2 bucket create gym-photos
npx wrangler r2 bucket create gym-photos-private
npx wrangler r2 bucket create exercise-photos
```

- [ ] Put the printed `database_id` in `server/wrangler.jsonc` in place of `00000000-0000-0000-0000-000000000000`, and
      commit it (`chore(server): the deployed D1 database id`). It isn't a secret.
- [ ] Afterwards `scripts/server-up.sh` may start with an empty local D1, if local state is keyed by the id. Run it
      once more to migrate it. The tests use an in-memory D1 and don't care.
- [ ] The three buckets stay private: no public bucket access, and no `r2.dev` address. The Worker serves the photos.
- [ ] R2 may ask for a payment method on the account before the first bucket, even within its free tier. Use past the
      free tier is billed, which is what section 6's alerts are for.

## 3. Secrets and settings (owner's approval)

```bash
openssl rand -base64 48 | npx wrangler secret put BETTER_AUTH_SECRET    # 48 random bytes; never printed or saved
```

- [ ] If wrangler offers to create the Worker for the secret, accept: the deploy in step 4 fills it.
- [ ] `git check-ignore -q server/.dev.vars && echo ignored` prints `ignored`: the local secrets file never reaches git.
- [ ] If the secret may have leaked, put a new one with the same command. Expect to sign in again, in the app and in
      Claude.
- [ ] `ALLOW_PASSWORD_AUTH` stays `"0"` in `server/wrangler.jsonc`, and no variable in the dashboard overrides it.
      Email and password sign-in is for local tests only.
- [ ] `APPLE_BUNDLE_ID` stays `com.rollins.gymrollins`: Apple's id tokens carry it as their audience.
- [ ] `PUBLIC_BASE_URL` must be `<origin>`: the OAuth issuer and the MCP resource are built from it.
      `server/wrangler.jsonc` keeps the local `http://127.0.0.1:8787`, so every deploy passes it (step 4).

## 4. Migrate and deploy (owner's approval)

**Order.** The Worker is deployed before the app build that points at it, or with it, never after. The app relies on
`404 no_such_proposal` for a missing proposal, and an older server answers differently.

On every deploy after the first, note a Time Travel bookmark first (section 7), so a migration can be undone.

```bash
npx wrangler d1 migrations apply gymrollins --remote
npx wrangler deploy --var PUBLIC_BASE_URL:<origin>
```

Then check from any machine. These need no account:

```bash
BASE=<origin>
curl -s -o /dev/null -w '%{http_code}\n' "$BASE/v1/sync/profile"            # 401
curl -si -X POST "$BASE/mcp" | grep -i '^www-authenticate'                 # resource_metadata="<origin>/.well-known/oauth-protected-resource/mcp"
curl -s "$BASE/.well-known/oauth-protected-resource/mcp"                  # "resource":"<origin>/mcp"
curl -s "$BASE/.well-known/oauth-authorization-server"                    # "issuer":"<origin>/api/auth"
curl -s -X POST "$BASE/api/auth/sign-up/email" -H 'content-type: application/json' \
  -d '{"email":"probe@example.com","password":"correct-horse-battery","name":"probe"}'   # email_password_sign_up_disabled
```

The opener's place on the approve sheet comes from `request.cf`, which Cloudflare sets on every request. No zone
setting or header is needed, and a `cf-ipcity` header a client sends is ignored (the code never reads client headers). Section 11 checks the place.

If the metadata names `http://127.0.0.1:8787`, the deploy missed `--var PUBLIC_BASE_URL`. Deploy again with it.

**If a deploy goes wrong** (owner's approval):
- `npx wrangler deployments list` shows the versions, and `npx wrangler rollback <version-id>` puts an earlier one back.
- A rollback leaves D1 as it is. If the bad deploy came with a migration the old Worker can't read, restore the
  bookmark noted before it (section 7). That also undoes every write made since.
- Hold back the app build that needed the new Worker (the order above) until the Worker it needs is back.

## 5. Usage caps (plan 31 built them; decide what is open before step 2)

**Built** (plan 31, `server/migrations/0010_account_caps.sql`; the numbers are `DomainLimits`', in
`ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift`):
- Per account, deleted rows included: 10,000 workouts, 50,000 exercises and 250,000 sets logged in them, 20,000
  weigh-ins, 200 routines, 1,000 custom exercises, 2,000 exercise preferences, 500 private gyms and 5,000 private
  listings.
  - **Deleted rows count.** A deletion stays as a tombstone (`deleted_at`), so other devices learn of it, and nothing
    purges tombstones. So deleting frees nothing: an account that reaches a cap stays there. Only sets removed from a
    workout free room.
- Private gyms (100) and private listings (1,000) also keep their live caps (`0005_gyms_photos.sql`).
- Claude: 100 proposals waiting for review at a time, and 5,000 in all.
- One workout holds at most 50 exercises, and an exercise at most 50 sets in it. The app stops there, and the importers
  split a bigger workout into several ("Push", "Push (2)").
- A refused row stays on the phone. Account lists it under "N items couldn't sync", with the server's words, and it
  isn't sent again until it is edited.
- One account at the caps holds about 70 MB of sets; a free D1 database holds 500 MB in all.

**Open** (plan 31, "Questions for the owner"):
- [ ] Claude's audit rows: 90 days kept, up to 60 a minute.
- [ ] A big workout re-saved again and again: about 10,000 rows written a save at both per-workout caps, against the
      free plan's 100,000 a day. Section 1's rate limits are the only guard.
- [ ] **Unused OAuth clients** (owner's approval for each run). Better Auth keeps every registration, and registration
      is open. Run this monthly. It removes clients older than a day that hold no token and no consent. Save the query
      in a file outside the repo, then run it:

      ```sql
      DELETE FROM "oauthClient" WHERE "createdAt" < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day') AND NOT EXISTS (SELECT 1 FROM "oauthAccessToken" t WHERE t."clientId" = "oauthClient"."clientId") AND NOT EXISTS (SELECT 1 FROM "oauthRefreshToken" t WHERE t."clientId" = "oauthClient"."clientId") AND NOT EXISTS (SELECT 1 FROM "oauthConsent" c WHERE c."clientId" = "oauthClient"."clientId");
      ```

      ```bash
      cd server && npx wrangler d1 execute gymrollins --remote --file <that file>
      ```

## 6. Spend and usage alerts (owner's approval)

- [ ] Cloudflare dashboard › Notifications: usage alerts for Workers and R2, and a billing alert for R2.
- [ ] When a free daily limit is reached (100,000 Worker requests; D1's rows read and written), the Worker stops
      answering until the next day. The app shows that as offline, and nothing is lost on the phone.

## 7. Data safety (owner's approval)

- [ ] D1 Time Travel is on by default (7 days on the free plan). Before the phone moves, note a bookmark:
      `npx wrangler d1 time-travel info gymrollins`.
- [ ] To go back to a bookmark: `npx wrangler d1 time-travel restore gymrollins --bookmark=<bookmark>`.
- [ ] After the move, export a copy outside the repo, because it holds the owner's personal data:
      `npx wrangler d1 export gymrollins --remote --output <a folder outside the repo>/gymrollins-$(date +%Y%m%d).sql`.
- [ ] Time Travel covers D1 only. R2 has no way back: a deleted photo is gone. The exercise photos can be uploaded
      again (section 8); private gym photos can't.

## 8. Exercise photos in the deployed bucket (owner's approval)

So far only the local bucket has them. From the repo root:

```bash
GYM_CLOUD_APPROVED=1 WORKER_URL=<origin> node scripts/upload-photos.mjs --target cloud --dry-run
GYM_CLOUD_APPROVED=1 WORKER_URL=<origin> node scripts/upload-photos.mjs --target cloud
curl -s "<origin>/photos/exercises/manifest.json" | head -c 300
```

- `--target cloud` writes with `wrangler r2 object put --remote` (the owner's login) and reads back through the
  Worker.
- It refuses to run without `GYM_CLOUD_APPROVED=1`.
- A second run uploads nothing.

## 9. Point the app at the Worker (owner's approval)

- [ ] In `ios/Config/Local.xcconfig` (gitignored), set `API_URL = https:/$()/<origin's host>`. The `/$()/` keeps
      xcconfig from reading `//` as a comment.
- [ ] Once section 8 is done, also set `PHOTO_HOSTING = storage`. Keep `DEVELOPMENT_TEAM`.
- [ ] Keep only settings the app reads (`API_URL`, `PHOTO_HOSTING`, `SHARE_LINK_HOST`, signing). Drop any left from the
      old backend.
- [ ] The first launch of a build with a new `API_URL` runs the server move, so build for the phone only in step 10.

## 10. Back up the phone, install, sign in, compare (owner's approval)

Back up the app's data first: the phone holds the only live copy of the training data.

```bash
xcrun devicectl list devices                                   # the iPhone's identifier
BACKUP="$HOME/GymRollins-backups/phone-$(date +%Y%m%d-%H%M)"     # outside the repo
mkdir -p "$BACKUP"
xcrun devicectl device copy from --device <iPhone id> --domain-type appDataContainer \
  --domain-identifier com.rollins.gymrollins --source Library --destination "$BACKUP/Library"
xcrun devicectl device copy from --device <iPhone id> --domain-type appDataContainer \
  --domain-identifier com.rollins.gymrollins --source Documents --destination "$BACKUP/Documents"
```

Copy the two folders one by one: copying the container's root fails on a system plist.

Never open the backup's `default.store` in place. Opening it with `sqlite3` rewrites its write-ahead log (`-wal`), and
the backup stops being a copy of the phone. Read a copy of it instead:

```bash
READ="$(mktemp -d)"                                                 # outside the repo; remove it when you are done
cp "$BACKUP/Library/Application Support/default.store"* "$READ/"    # the store with its -wal and -shm
sqlite3 "$READ/default.store" "select count(*) from ZWORKOUTRECORD"
```

- [ ] Rehearse on the simulator with a fresh copy of this backup and a throwaway local Worker:
      `scripts/server-move-check.sh "$BACKUP" <a work folder outside the repo>`. It only reads the backup, and puts
      its own copies in the work folder. It must end `Server move verified.`
- [ ] Note a Time Travel bookmark (section 7).
- [ ] Build and install as `docs/release-readiness.md` ("Device build") says.
- [ ] Open the app. Sign in with Apple. Wait until the Account screen says "Up to date".
- [ ] Compare D1 with the backup. The phone's side (active workouts never sync):

      ```bash
      sqlite3 "$READ/default.store" "select (select count(*) from ZWORKOUTRECORD where ZISACTIVE = 0), (select count(*) from ZWORKOUTENTRYRECORD e join ZWORKOUTRECORD w on e.ZWORKOUT = w.Z_PK where w.ZISACTIVE = 0), (select count(*) from ZSETRECORD s join ZWORKOUTENTRYRECORD e on s.ZENTRY = e.Z_PK join ZWORKOUTRECORD w on e.ZWORKOUT = w.Z_PK where w.ZISACTIVE = 0), (select count(*) from ZROUTINERECORD), (select count(*) from ZBODYWEIGHTRECORD)"
      ```

      D1's side:

      ```bash
      cd server && npx wrangler d1 execute gymrollins --remote --command "select (select count(*) from workouts) as workouts, (select count(*) from workout_entries) as entries, (select count(*) from workout_sets) as sets, (select count(*) from routines) as routines, (select count(*) from bodyweight) as body_weights"
      ```

      The five numbers match. The rehearsal copy of 2026-11-08 held 148, 836, 2,685, 6 and 23.
- [ ] If they don't match, change nothing on the phone. The backup and the Time Travel bookmark are the way back.

## 11. Connect Claude on claude.ai (owner's approval)

- [ ] claude.ai › Settings › Connectors › Add custom connector, with the URL `<origin>/mcp`. Settings › Claude in the
      app shows the same address.
- [ ] Connect. The browser shows the sign-in page with a code, `XXXX-XXXX`.
- [ ] In the app, open Settings › Claude › Approve a connection and type the code. Check the client's name, that
      the host is claude.ai or claude.com (any other host shows a warning), and that the place it names is where you
      are: it comes from `request.cf`. Approve.
- [ ] The page says "Approved, returning to Claude…", and claude.ai shows the connector as connected.
- [ ] In a chat, ask Claude to read your profile (the `get_profile` tool). Settings › Claude shows the last use.
- [ ] Re-run the connection and sync checks against the deployed Worker:
  - section 4's checks;
  - a weigh-in edited on the phone syncs ("Up to date");
  - a proposal Claude makes reaches the app.

  `scripts/claude-local.mjs smoke` can't run against the deployed Worker: it signs in by email, which the deployed
  Worker refuses.
- [ ] Client metadata documents stay off unless claude.ai needs them. If claude.ai sends one instead of registering,
      the connection fails with `invalid_client`. Plan 29 left them off (its decision 4); turning them on is a change
      of its own.

## 12. Afterwards

- [ ] This project's local containers of the old backend are still running: plans 26–30 never stopped them.
  - Stopping them is a separate decision for the owner.
  - They are the containers whose names end in `_gymrollins`: `docker ps --format '{{.Names}}' | grep '_gymrollins$'`.
  - Plan 30 deleted the old config file, the only record of how to address them as a group. Its project id was
    `gymrollins`. Stop them with `docker stop` on each container the command above lists.
  - Containers of other projects are never touched, and the data volumes stay until the owner removes them.
- [ ] Untracked leftovers of the old backend stay on disk: its folder and `web/consent/`, with their `.env.local` files
      (gitignored, so git never removed them). Nothing in the repo uses them. The owner deletes them by hand:
      delete the old backend's folder and `web/consent`.
- [ ] Once the phone has moved, `OldServerKeychain` can go, with its one exception in the old-backend guard
      (`scripts/check-old-backend.sh`, added by plan 30's last task), in a change of their own. During the move it deletes the old sign-in SDK's Keychain items.
