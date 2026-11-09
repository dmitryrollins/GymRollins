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

**The config is the deployed Worker.** The top level of `server/wrangler.jsonc` holds the production values: the
custom domain `api.gymrollins.com`, no `workers.dev` address and no preview URLs, `PUBLIC_BASE_URL` set to `<origin>`,
and `BETTER_AUTH_SECRET` required. So a plain `npx wrangler deploy` can't ship a local address, and no deploy step
passes `--var`. There are no wrangler environments, so no `--env` either.
- The local starts pass their own values: `scripts/server-up.sh`, `scripts/test-server.sh` and `npm run dev` add
  `--var PUBLIC_BASE_URL:http://127.0.0.1:<port>` and `--infer-origin-from-routes=false` (without it, wrangler dev
  shows the Worker the custom domain as its own address).
- `server/test/wrangler-config.test.ts` checks both sides.
- A bare `npx wrangler dev` advertises `<origin>` in its OAuth metadata and refuses email sign-up. It still uses
  only local data. Start the local Worker with the scripts.

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
these paths want a per-IP rule from Cloudflare, before anything else is done:
- `/api/auth/*`: sign-in, authorize and token,
- `/api/auth/oauth2/register`: dynamic client registration, with the tightest limit,
- `/connect`: Claude's sign-in page,
- `/v1/*`: the app's reads and pushes,
- `/mcp`: Claude's calls (the Worker already allows 60 a minute per account).

**The owner chose A, a custom domain** (2026-11-08): the Worker answers on `https://api.gymrollins.com`, with the
per-IP rules below. Cloudflare's rate-limiting rules belong to a zone, which is a domain on the account. The free
`*.workers.dev` address isn't one, so no rule can be put on it. The two options were:
- **A. A custom domain.**
  - The zone `gymrollins.com` is active on the VIPPIE LLC account (Free plan). `server/wrangler.jsonc` routes the
    Worker to `api.gymrollins.com` (`"custom_domain": true`) and sets `"workers_dev": false` and
    `"preview_urls": false`: a preview address would skip the zone's rules too.
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

The rule to create now, in the dashboard (the Free plan's limit is one rule, with a 10-second window; the page shows
it):
- [ ] Security › Security rules › Create rule › Rate limiting rules on `gymrollins.com` (the older dashboard:
      Security › WAF › Rate limiting rules), one rule:
  - expression: `(starts_with(http.request.uri.path, "/api/auth/") or starts_with(http.request.uri.path, "/connect"))`.
    The Free plan's rules can match the path only, not the host, so the rule also covers those paths on
    `gymrollins.com` itself, where the website has none. If the editor refuses `starts with`, use `wildcard` with
    `/api/auth/*` and `/connect*`.
  - counted per IP, 20 requests per 10 seconds, action Block, duration 10 seconds (the Free plan's only window and
    timeout).
  - Done on 2026-11-09 as "API sign-in limit", right after the first deploy. Checked with 30 quick requests to
    `/api/auth/get-session`: 25 answered 200, then 429. `/v1/sync/profile` still answered meanwhile, and the block
    lifted after 10 seconds. The count is approximate (Cloudflare counts per data center).
- [ ] It covers registration (`/api/auth/oauth2/register`), sign-in, authorize and token, and `/connect`, which
      share its limit. `/v1/*` and `/mcp` keep only the Worker's own caps (above). Widening the rule to them is the
      owner's call.

## 2. Create the resources (owner's approval)

- [ ] R2 is enabled on the VIPPIE LLC account (dashboard › R2 Object Storage). It may ask for a payment method first,
      even within its free tier, and `r2 bucket create` fails until it is enabled. Use past the free tier is billed,
      which is what section 6's alerts are for.

```bash
cd server
export CLOUDFLARE_ACCOUNT_ID=<account-id>   # VIPPIE LLC (the top of this list)
npx wrangler whoami                                             # lists VIPPIE LLC; if not, npx wrangler login
npx wrangler d1 create gymrollins --no-update-config            # prints the database_id
npx wrangler r2 bucket create gym-photos --no-update-config
npx wrangler r2 bucket create gym-photos-private --no-update-config
npx wrangler r2 bucket create exercise-photos --no-update-config
```

`--no-update-config` stops wrangler from writing the new resource into `server/wrangler.jsonc` itself: it would add a
second binding, or, given `--binding`, rewrite the whole file in its own format.

Then put the printed `database_id` in place of the placeholder, and commit it. It isn't a secret.

```bash
DB_ID=<the database_id d1 create printed>
sed -i '' "s/00000000-0000-0000-0000-000000000000/$DB_ID/" wrangler.jsonc
git diff --stat wrangler.jsonc                 # 1 file changed, 1 insertion(+), 1 deletion(-)
npx vitest run test/wrangler-config.test.ts    # all pass: database_id is a UUID, everything else unchanged
git add wrangler.jsonc && git commit -m "chore(server): the deployed D1 database id"
```

- [ ] Afterwards `scripts/server-up.sh` starts with an empty local D1: local state is keyed by `database_id`. It
      migrates the new one on start; the old local data stays in its file, unused. The tests use an in-memory D1,
      and `scripts/test-server.sh` a throwaway one.
- [ ] The three buckets stay private: no public bucket access, and no `r2.dev` address. The Worker serves the photos.

## 3. Secrets and settings (checks; nothing runs here)

- [ ] `BETTER_AUTH_SECRET` goes up with the Worker's first version, in step 4's first deploy, so the Worker never
      runs without it. `"secrets": { "required": ["BETTER_AUTH_SECRET"] }` in `server/wrangler.jsonc` makes wrangler
      refuse any deploy that would leave it out. `wrangler secret put` before the Worker exists would first make a
      placeholder Worker to hold it, so step 4 doesn't use it.
- [ ] To replace the secret later (the Worker exists then), for instance if it may have leaked. Expect to sign in again,
      in the app and in Claude:

      ```bash
      cd server && export CLOUDFLARE_ACCOUNT_ID=<account-id>
      openssl rand -base64 48 | npx wrangler secret put BETTER_AUTH_SECRET    # 48 random bytes; never printed or saved
      ```
- [ ] `git check-ignore -q server/.dev.vars && echo ignored` prints `ignored`: the local secrets file never reaches git.
- [ ] `ALLOW_PASSWORD_AUTH` stays `"0"` in `server/wrangler.jsonc`, and no variable in the dashboard overrides it
      (a deploy without `--keep-vars` removes dashboard variables). Email and password sign-in is for local tests only.
- [ ] `APPLE_BUNDLE_ID` stays `com.rollins.gymrollins`: Apple's id tokens carry it as their audience.
- [ ] `PUBLIC_BASE_URL` is `<origin>` in `server/wrangler.jsonc`: the OAuth issuer and the MCP resource are built from
      it. No deploy passes `--var`.
- [ ] `api.gymrollins.com` has no DNS record of its own yet (DNS › Records): the first deploy creates it and its
      certificate. With the secret piped in, that deploy can't ask questions, so it would replace such a record
      without asking.

## 4. Migrate and deploy (owner's approval)

**Order.** The Worker is deployed before the app build that points at it, or with it, never after. The app relies on
`404 no_such_proposal` for a missing proposal, and an older server answers differently.

On every deploy after the first, note a Time Travel bookmark first (section 7), so a migration can be undone.

The first deploy, from the commit that holds the `database_id` (step 2):

```bash
cd server
export CLOUDFLARE_ACCOUNT_ID=<account-id>   # VIPPIE LLC (the top of this list)
git status --short wrangler.jsonc                               # prints nothing: the committed config
npx wrangler deploy --dry-run --outdir "$(mktemp -d)"           # local build only; the bindings list shows
                                                                #   PUBLIC_BASE_URL ("https://api.gymrollins.com")
npx wrangler d1 migrations apply gymrollins --remote            # lists 0001 to 0010; confirm
openssl rand -base64 48 | sed 's/^/BETTER_AUTH_SECRET=/' | npx wrangler deploy --secrets-file /dev/stdin
```

The last line makes the secret (48 random bytes) and hands it to the Worker's first version through a pipe: it is
never printed or saved. wrangler 4.158.0 reads `--secrets-file` as a dotenv file, and refuses an empty one. It lists
`api.gymrollins.com (custom domain)` as the target.

Done on 2026-11-09 (versions 3106d03f, then e589e8da). The first deploy printed `Uploaded gymrollins`, then failed
with `This Worker does not exist on your account. [code: 10007]`: Cloudflare didn't know the new Worker yet when
wrangler asked for it to attach the domain. The upload had landed with the secret (`npx wrangler secret list` showed
`BETTER_AUTH_SECRET`), so a plain `npx wrangler deploy` attached `api.gymrollins.com`. If it happens again, don't
send a second secret: check the list, then run the plain deploy.

Every deploy after the first keeps the secret it has:

```bash
cd server
export CLOUDFLARE_ACCOUNT_ID=<account-id>
npx wrangler d1 migrations apply gymrollins --remote            # only when the deploy brings a migration
npx wrangler deploy
```

**Plan 32 (AI agents) brings migration `0011_ai_agents.sql`.** It only adds columns, each with its default, so the app
on the phone keeps working with it: a profile pushed without `mcp_log_workouts` is stored with Add workouts off. In
this order, from `server/` with `CLOUDFLARE_ACCOUNT_ID` exported:
1. Note a Time Travel bookmark (section 7): `npx wrangler d1 time-travel info gymrollins`.
2. `npx wrangler d1 migrations apply gymrollins --remote`: it lists `0011_ai_agents.sql` alone; confirm.
3. `npx wrangler deploy`, then the checks below. With `BASE` set as they set it,
   `curl -s -o /dev/null -w '%{http_code}\n' "$BASE/v1/agents"` prints 401 (the route is there, behind the session).
4. Only then the app build that shows Settings › AI agents.

Then check from any machine. These need no account:

```bash
BASE=https://api.gymrollins.com
curl -s -o /dev/null -w '%{http_code}\n' "$BASE/v1/sync/profile"            # 401
curl -si -X POST "$BASE/mcp" | grep -i '^www-authenticate'                 # resource_metadata="<origin>/.well-known/oauth-protected-resource/mcp"
curl -s "$BASE/.well-known/oauth-protected-resource/mcp"                  # "resource":"<origin>/mcp"
curl -s "$BASE/.well-known/oauth-authorization-server"                    # "issuer":"<origin>/api/auth"
curl -s -X POST "$BASE/api/auth/sign-up/email" -H 'content-type: application/json' \
  -d '{"email":"probe@example.com","password":"correct-horse-battery","name":"probe"}'   # email_password_sign_up_disabled
```

The opener's place on the approve sheet comes from `request.cf`, which Cloudflare sets on every request. No zone
setting or header is needed, and a `cf-ipcity` header a client sends is ignored (the code never reads client headers). Section 11 checks the place.

The metadata names `<origin>` because `server/wrangler.jsonc` does. If it names anything else, the deployed config
isn't the committed one: roll back (below) and run `npx vitest run test/wrangler-config.test.ts`.

Then the exercise photos (section 8).

**If a deploy goes wrong** (owner's approval), from `server/` with `CLOUDFLARE_ACCOUNT_ID` exported:
- `npx wrangler deployments list` shows the versions, and `npx wrangler rollback <version-id>` puts an earlier one back.
- The first deploy has no earlier version. Until the app and Claude point at it, nothing depends on it.
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

So far only the local bucket has them. Right after section 4's checks:

```bash
cd server
export CLOUDFLARE_ACCOUNT_ID=<account-id>   # VIPPIE LLC (the top of this list)
GYM_CLOUD_APPROVED=1 WORKER_URL=https://api.gymrollins.com node ../scripts/upload-photos.mjs --target cloud --dry-run
GYM_CLOUD_APPROVED=1 WORKER_URL=https://api.gymrollins.com node ../scripts/upload-photos.mjs --target cloud
curl -s "https://api.gymrollins.com/photos/exercises/manifest.json" | head -c 300
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
- [x] Once the phone has moved, `OldServerKeychain` can go, with its one exception in the old-backend guard
      (`scripts/check-old-backend.sh`, added by plan 30's last task), in a change of their own. During the move it deletes the old sign-in SDK's Keychain items.
      Done on 2026-11-09, after the phone's move had verified (148 workouts on the server, as in the backup).
