# Handoff: where things stand (2026-11-13)

Written so a new session on another machine can pick up the work. Plans and their outcomes are in `docs/plans/`.

## Branches

PR #3 merged all of these into `main` on 2026-11-13, so work from `main` now. Each branch was built on the one before it:

| Branch | What it adds |
|---|---|
| `feat-week-plan` | Plan 34 (the week is the plan), with plan 35 (`feat-agent-says-done`) merged in |
| `feat-workout-fixes` | Plan 36 (workout screen fixes) |
| `feat-workout-polish` | Plan 37 (keyboard bar, app icon, Body switch, muscle map) |
| `feat-weights-lb` | Plan 38 (weights keep their pound number). The owner's phone runs aa2f311 |
| `feat-testflight` | TestFlight prep under VIPPIE LLC, on top of everything above |

## What's live

- **Server** `api.gymrollins.com`: Worker version 0b30adbf, the server code now on `main`. D1 has every migration up to 0012.
  - It accepts Sign in with Apple id tokens for both bundle ids (`APPLE_BUNDLE_IDS` in `server/wrangler.jsonc`).
- **Owner's phone:** `feat-weights-lb` aa2f311, bundle id `com.rollins.gymrollins`, synced with the server.

## Next steps

1. **TestFlight under VIPPIE LLC.** The owner is doing the first two steps:
   - add VIPPIE's Apple ID in Xcode › Settings › Accounts (Admin role, so Xcode can make the distribution certificate);
   - create the App Store Connect app: iOS, GymRollins, English (U.S.), bundle id `com.gymrollins.app`, any SKU.

   Then archive from `ios/`. Run `xcodegen` first if the project is missing:

   ```sh
   xcodebuild -project GymRollins.xcodeproj -scheme GymRollins -configuration Release \
     -destination 'generic/platform=iOS' -archivePath build/GymRollins-TF.xcarchive \
     -allowProvisioningUpdates DEVELOPMENT_TEAM=<VIPPIE team id> \
     API_URL=https://api.gymrollins.com PHOTO_HOSTING=storage archive
   ```

   - Upload with `xcodebuild -exportArchive -allowProvisioningUpdates`. The export options plist needs `method` app-store-connect, `destination` upload, `teamID`, `signingStyle` automatic.
   - The build is version 1.0 (1). Internal testers need no review.
2. **Account link after the first TestFlight sign-in.** Sign in with Apple user ids belong to one developer team, so the first sign-in in the VIPPIE app makes a new, empty account. Hide My Email addresses also change with the team.
   - Fix: point the new apple `account` row at the owner's existing user, then delete the empty user.
   - This writes to the production D1. It needs the owner's OK, with a time-travel bookmark taken first.
3. **Plan 38 check on the phone.** After the owner has opened the app once, count the plan weights that have a pound number in a *copy* of the store. Expect 37: 12 snapped to the grid, 25 that only gained the number.
4. **Older open items:**
   - Plan 34 Task 9 (screenshots and Outcome).
   - The website plan 3 questions.
   - Deleting the `STAGING_PASSWORD` secret.
   - `www` DNS.

## Setting up a new machine

- Work on `main`, or on a new branch from it. Run `cd ios && xcodegen`: the Xcode project and the Info.plists are generated, not committed.
- `ios/Config/Local.xcconfig` (gitignored) holds `DEVELOPMENT_TEAM = <team id>`. For a build that updates the phone's existing install, also put `APP_BUNDLE_ID = com.rollins.gymrollins` there, or pass it on the command line.
- `cd server && npm ci`. Copy `server/.dev.vars` from the old machine by hand: it holds secrets and is never committed or printed.
- `npx wrangler login` with a login that sees the VIPPIE LLC account. `docs/cloudflare-checklist.md` covers the rest.
- Tests:
  - app: `scripts/ios-test.sh`;
  - server: `npm test` and `npm run typecheck` in `server/`;
  - packages: `swift test` in each `ios/Packages/*`.

## How this project is worked on

- **No attribution trailers** in commits or PRs. That means no `Co-Authored-By`, no "Generated with" and no session links.
- **The repo is public.** Before every push or PR, scan the commits and their messages for:
  - the Mac user's surname (it's part of the home folder path, so watch absolute paths and symlinks);
  - the Cloudflare account id;
  - secrets.

  Owner data never goes in the repo; test data is synthetic.
- **Ask the owner first** before any Cloudflare step (deploy, migration, secret, D1 write) and before any install on the phone.
- **Before an install on the phone**, back up the app's `Library/Application Support` and `Library/Preferences` with `xcrun devicectl device copy from`. Then compare row counts before and after.
  - Count rows on copies of the store, never on the backup in place: opening it with sqlite3 rewrites the files.
  - The phone has to be unlocked to launch the app, so the first open is the owner's.
- Don't run `scripts/test-db.sh`: it resets the local server.
