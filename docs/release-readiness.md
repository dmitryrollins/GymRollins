# Release readiness — v0.1.0

Status as of 2026-09-28, branch `plan-08-e2e-polish` (Plan 08, Task 5), all commits through
`7b96daf`. Full local test matrix is green: `scripts/test-all.sh`, `scripts/test-db.sh` (147),
`cd supabase/functions && deno test` (MCP), `scripts/test-sync-integration.sh` (15),
`scripts/ios-test-sync.sh` (5/5), SwiftLint (0 errors), `deno lint` (clean).

## What works locally

Everything below runs against the local Supabase stack (`scripts/supabase-up.sh`) or fully
offline, and is proven by the listed suites.

| Feature | Proven by |
|---|---|
| Onboarding: Sign in with Apple/email, profile setup (units, body, goal, days, injuries) | `OnboardingUITests`, `ProfileSetupInputTests`, `AuthServiceTests` |
| Fitbod CSV import + column mapping + unmatched-exercise resolution | `OnboardingUITests::testFullOnboardingWithImport`, `CSVParserTests`, `FitbodImporterTests`, `ImportPlanTests`, `ImportServiceTests`, `RealExportImportTests`, `docs/import/fitbod-alias-review.md` |
| Today: next routine, suggested weights, progression engine | `ShellUITests`, `TodayModelTests`, `ProgressionEngineTests` |
| Live logging: warm-up flag, done checks, rest timer, plate calculator, workout clock, exercise how-to, notes | `WorkoutFlowUITests`, `WorkoutScreensUITests`, `FlowCoverageUITests`, `SmokeTests` |
| History: workout summary, PRs, estimated 1RM, per-exercise history/trend, share sheet | `LogUITests`/`WorkoutFlowUITests`, `HistoryTests`, `FlowCoverageUITests::testStep4_2...ShareSheet` |
| Body tracking: bodyweight/body-fat log, goal progress, trend | `BodyUITests`, `BodyTrendTests`, `BodyweightChartDomainTests` |
| Exercise library: search, filters, custom exercises usable in routines/workouts | `LibraryUITests`, `LibraryTests`, `FlowCoverageUITests::testStep5_2...` |
| Exercise photos (free-exercise-db stopgap): detail/how-to, logging hero, row thumbnails; offline cache; illustration fallback | `ExercisePhotoUITests` (hermetic stub photos), `ExerciseMediaProviderTests`, `ExercisePhotoStoreTests`, `ExercisePhotoModelTests`, `node --test scripts/map-exercise-photos.test.mjs` |
| Settings: units, rest, bar/plates, import/export, account deletion | `SettingsUITests`, `ExportServiceTests`, `AuthIntegrationTests::deleteAccountRemovesUserAndData` (E2E) |
| Offline-first sync, conflict resolution (keep local / keep other), resume after relaunch | `SyncUITests`, `ConflictUITests`, `SyncEngineTests`, `SyncCoordinatorTests`, `SyncRoundTripTests` (E2E) |
| Empty states across Today/Log/Library | `EmptyStatesUITests` |
| Claude connection screen, proposal review (apply/undo, auto-apply), MCP read/write tools, OAuth consent page and DCR flow (local) | `ProposalUITests`, `ClaudeConnectionBadgeTests`, `mcp/tools/*_test.ts`, `mcp_hardening.test.sql`, `mcp_audit.test.sql`, `web/consent/server.test.mjs`, `web/consent/e2e.test.mjs` (headless Chromium) |
| Accessibility: VoiceOver labels, Dynamic Type up to accessibility XL, `performAccessibilityAudit()` | `AccessibilityAuditUITests`, screenshots in `docs/screenshots/plan-08/a11y/` |
| Repository query performance (150-workout history) | `WorkoutRepositoryPerformanceTests` — all six queries under the 50 ms target, see `docs/testing/performance.md` |

Full step-by-step mapping: `docs/testing/flow-coverage.md` (30 of 32 flow-map steps covered end to
end; the remaining 2 are partial only because they hit surfaces XCUITest can't drive — the Sign in
with Apple system sheet, and the routine editor's superset/progression controls, which only change
through Claude proposals and are covered there).

Run everything: `scripts/test-all.sh` (opt-in Docker suites: `SYNC_E2E=1`, `MCP_E2E=1`). Full
command list in the README's test matrix.

## Needs the cloud project

Everything below needs an owner-approved Supabase cloud project; none of it can be verified
locally. See `docs/cloud-checklist.md` for the exact settings to change before pointing a build at
it (email confirmation, minimum password length or disabling the email provider, closing
sign-ups after the owner registers, the OAuth consent page showing client name/scope, the Apple
auth provider, RLS/`anon` advisor checks, `pgcrypto` in `extensions`).

- **The Claude connector end to end.** The full "add custom connector" flow inside claude.ai/the
  Claude Desktop app needs public HTTPS — the OAuth 2.1 dynamic client registration, authorize,
  and token endpoints all have to be reachable from claude.ai's servers, which `127.0.0.1:5xxxx`
  never will be. Locally we've verified every piece up to that boundary: `scripts/oauth-local-smoke.sh`
  automates DCR → PKCE → authorize → consent → token exchange → `tools/list`, and
  `web/consent/e2e.test.mjs` drives the consent page itself in headless Chromium.
- **Sign in with Apple.** Requires `[auth.external.apple]` configured in the cloud project
  (Services ID / bundle id, key id, team id, private key in the Supabase dashboard) and the
  app's `com.apple.developer.applesignin` entitlement pointed at a matching bundle id. Locally,
  auth is exercised with email/password (DEBUG-only in the shipping app).
- **TestFlight builds.** Needs a distribution certificate/provisioning profile under an App Store
  Connect app record, which needs the owner's Apple Developer Program membership context — see
  "Device build" below for the closest thing tested locally (a Debug device build).
- **A hosted consent page.** `web/consent/` currently only runs via `scripts/consent-server.mjs`
  bound to `127.0.0.1:55430`. For a cloud project it needs to be hosted somewhere with HTTPS and
  `[auth] site_url` pointed at it; the page itself (static HTML/JS/CSS, CSP already set) doesn't
  change, just where it's served from and `/config.js`'s cloud `SUPABASE_URL`/anon key.
- **Asymmetric JWT keys.** Local Supabase uses a shared HS256 secret; production should move to
  the ES256/RS256 asymmetric JWT signing Supabase cloud projects support, which the MCP Edge
  Function's token validation already expects to work with (JWKS-based verification) but hasn't
  been exercised against a real asymmetric-key issuer.

## Deferred

**From the spec's "Not in v1"** (`docs/specs/2026-09-26-gymrollins-ios-design.md`): recovery
muscle map, weekly set targets, streaks, Apple Health, Apple Watch, in-app AI chat, and importers
for other apps (Strong, Hevy, FitNotes).

**Next planned feature (already agreed with the owner, not part of v1 scope): a lock-screen Live
Activity** for the rest timer — shows the rest countdown, the exercise, and a line like
"Set 3/5 · 60 kg × 8", with Log set / +30s / Skip rest actions. Planned values only (no live
reads from the running app state beyond what's needed to render), reps-mode exercises only
(timed/cardio excluded). Sized as its own branch off `main` after this plan merges, not bundled
into v1.

**Review backlog:** Task 4's full security review, code review, and Codex review ran over the
whole repo; every CRITICAL/HIGH/P0–P2 finding was fixed directly on this branch, test-first
(notably `3c40fac` CSV formula-injection neutralization + 25 MB import cap, `71a5880` sign-out
data-loss warning + Claude-disconnect confirmation, `63b6d5c` calendar-day goal dates,
`e5aa5e2` Bar & Plates edit precision, `ebfb991` dropped the unused `ComingSoonView` dead code).
No MEDIUM/LOW findings needed a `docs/reviews/backlog.md` — the reviews didn't surface any that
weren't folded into the fixes above.

**Performance, device measurements** (`docs/testing/performance.md`):
- Cold launch measured 1.80 s (RSD 0.9%) on the iPhone 17 Pro **simulator**, Debug build, vs. the
  < 1.5 s target — **missed**, but the simulator number overstates a device Release launch
  (simulator process spawn, Debug build, `-uiTesting` in-memory seeding, and decoding the bundled
  1,324-exercise library are all included; none of that is optimized in this pass). Candidates if
  a device Release measurement also misses: decode `exercises.json` off the main thread / lazily,
  defer non-UI seeding.
- Scroll hitch count/time ratio (`XCTOSSignpostMetric` hitch metrics) **are not reported by the
  simulator at all** — only deceleration/dragging durations, which were flat and met no
  content-dependent-stall bar. A real hitch measurement needs `scripts/test-perf.sh ui` run on a
  physical device, which needs the signing situation below resolved first.

## Owner decisions needed

- **Cloud project approval** — creating and configuring the Supabase cloud project per
  `docs/cloud-checklist.md`, and deciding when to cut over from local-only.
- **Exercise media — decided 2026-09-28: stopgap photos now, own AI media later.** The app shows
  public-domain start/end photos from `yuhonas/free-exercise-db` (Unlicense, pinned commit, see
  `docs/licenses/free-exercise-db.md`) for **300 / 1,324** library exercises (23 / 24 of the owner's
  routine lifts), matched conservatively by name + equipment (`docs/import/exercise-photo-review.md`).
  Photos load on demand from jsDelivr (pinned to the commit) and are cached on the device (Caches,
  150 MB cap), so they show offline after the first view; everything else keeps the body-part
  illustration. The opengym dataset's images/GIFs (© Gym visual) are still never used. **Still open:**
  producing GymRollins' own AI-generated images/GIFs — they plug in as the first
  `ExerciseMediaProvider` (own media → free-exercise-db → illustration) with no view changes; then
  decide whether to drop the stopgap photos.
- **App Store listing** — screenshots, description, category, age rating, and whether v0.1.0 goes
  out via TestFlight only or straight to review.
- **Privacy policy text review** — Settings already has a Privacy/About section
  (`03ed477`), but the actual policy copy (what's collected, Claude's access scope, data
  deletion) needs the owner's sign-off before it's user-facing/App-Store-facing.

## Device build

**Result (2026-09-28): signs, builds and installs on the owner's iPhone 14 Pro Max.**

```
cd ios && xcodegen generate
xcodebuild -project GymRollins.xcodeproj -scheme GymRollins \
  -destination 'generic/platform=iOS' -configuration Debug -allowProvisioningUpdates build
xcrun devicectl device install app --device <iPhone id> \
  ~/Library/Developer/Xcode/DerivedData/GymRollins-*/Build/Products/Debug-iphoneos/GymRollins.app
```

`-allowProvisioningUpdates` is required from the command line: without it `xcodebuild` won't
create the development profile and fails with "No profiles for 'com.rollins.gymrollins' were
found". The Apple ID signed in to Xcode already belongs to team `<TEAM_ID>`; the IDs in
parentheses in the keychain's "Apple Development: …" certificate names are personal certificate
IDs, not team IDs, so they don't need to match. Running from Xcode (select the iPhone, press Run)
does the same automatically.

First launch on a new device may need: Settings → Privacy & Security → **Developer Mode** on, and
Settings → General → VPN & Device Management → trust the developer certificate.

**Device sync caveat (documented, not tested on device):** `Base.xcconfig` defaults
`SUPABASE_URL` to `http://127.0.0.1:55421` (the Mac's local Supabase stack), overridden only by
`Local.xcconfig`, which does **not** currently set a `SUPABASE_URL`. A Debug or Release build
installed on a physical iPhone will resolve `127.0.0.1` to the *phone itself*, not the Mac, so
sync will fail (the app is fully usable offline — SwiftData is the local source of truth,
`SyncEngine` degrades to "offline, will sync later" the same way it does in airplane mode). For
device sync ahead of a cloud project: add `SUPABASE_URL = http:/$()/<Mac's LAN IP>:55421` to
`Local.xcconfig` (same split-`$()` trick `Base.xcconfig` uses so xcconfig doesn't treat `//` as a
comment) — the phone and Mac need to be on the same LAN/Wi-Fi, and `NSAllowsLocalNetworking` in
`Info.plist`'s `NSAppTransportSecurity` already permits plain-HTTP local-network traffic, so no
ATS change is needed. This is plausible but unverified on an actual device; it's the fallback
until the cloud project exists.

## How to install on your iPhone

1. Resolve the signing situation above (owner steps 1–6) so a Debug build can be signed for your
   team.
2. `cd ios && xcodegen generate` to regenerate the Xcode project from `project.yml`.
3. Open `GymRollins.xcodeproj` in Xcode, select your iPhone as the destination, and Run — or from
   the command line:
   ```
   xcodebuild -project ios/GymRollins.xcodeproj -scheme GymRollins \
     -destination 'generic/platform=iOS' -configuration Debug build
   ```
   (add `-allowProvisioningUpdates` only if you're comfortable letting Xcode manage the profile
   automatically; not required once step 1 is done via Xcode itself).
4. The app works fully offline out of the box (SwiftData local store, no network dependency for
   logging workouts). For sync against your Mac's local Supabase stack instead of the cloud
   project, see "Device sync caveat" above — add your Mac's LAN IP to
   `ios/Config/Local.xcconfig` and make sure `scripts/supabase-up.sh` is running and your phone
   is on the same network.
5. Onboard with Sign in with Apple (or, in a DEBUG build, email/password), import your Fitbod
   export if you have one, and set up your profile.
