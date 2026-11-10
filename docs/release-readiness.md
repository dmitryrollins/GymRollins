# Release readiness — v0.1.0

Status first written 2026-09-28 (Plan 08, Task 5); the backend parts were rewritten for the Cloudflare Worker in
plan 30 (2026-11-08). The full local matrix is `scripts/test-all.sh` with `SYNC_E2E=1 MCP_E2E=1 PHOTO_E2E=1
GYM_E2E=1`; each end-to-end suite starts its own throwaway local Worker. Plan 30's Outcome has the latest counts.

## What works locally

Everything below runs against the local Worker (`scripts/server-up.sh`, no Docker) or fully
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
| Claude connection screen, Approve a connection, proposal review (apply/undo, auto-apply), MCP read/write tools, the OAuth flow with the code page (local) | `ProposalUITests`, `ProposalSyncUITests`, `ClaudeConnectionBadgeTests`, `ApproveConnectionModelTests`, `server/test/mcp/**`, `server/test/connect-page.test.ts`, `connect-approve.test.ts`, `claude-connection.test.ts`, `scripts/test-mcp.sh` |
| Accessibility: VoiceOver labels, Dynamic Type up to accessibility XL, `performAccessibilityAudit()` | `AccessibilityAuditUITests`, screenshots in `docs/screenshots/plan-08/a11y/` |
| Repository query performance (150-workout history) | `WorkoutRepositoryPerformanceTests` — all six queries under the 50 ms target, see `docs/testing/performance.md` |

Full step-by-step mapping: `docs/testing/flow-coverage.md` (30 of 32 flow-map steps covered end to
end; the remaining 2 are partial only because they hit surfaces XCUITest can't drive — the Sign in
with Apple system sheet, and the routine editor's superset/progression controls, which only change
through Claude proposals and are covered there).

Run everything: `scripts/test-all.sh` (opt-in end-to-end suites, each on a throwaway local Worker: `SYNC_E2E=1`,
`MCP_E2E=1`, `PHOTO_E2E=1`, `GYM_E2E=1`). Full command list in the README's test matrix.

## Needs the deploy

Everything below needs the Worker deployed to the owner's Cloudflare account, which waits for the owner's approval
(`docs/cloudflare-checklist.md`, in its order: rate limits first). None of it can be verified locally.

- **The Claude connector end to end.** claude.ai must reach the Worker over public https: discovery, registration,
  authorize, `/connect` and the token endpoint. Locally every piece up to that boundary is covered:
  `scripts/test-mcp.sh` (and `node scripts/claude-local.mjs smoke`) runs registration → PKCE → authorize →
  `/connect` → the app's approval → tokens → MCP calls → refresh → Disconnect, and Claude Code connects to the local
  `/mcp` (`server/README.md`).
- **Sign in with Apple with a real Apple token.** The Worker checks the app's id token (audience = the bundle id,
  nonce, signature) with no web flow and no extra Apple setup. Locally it is tested with locally signed tokens; the
  first real token comes at the cutover. Email and password exist in debug builds only, and the deployed Worker keeps
  `ALLOW_PASSWORD_AUTH=0`.
- **TestFlight builds.** Needs a distribution certificate/provisioning profile under an App Store
  Connect app record, which needs the owner's Apple Developer Program membership context — see
  "Device build" below for the closest thing tested locally (a Debug device build).
- **The phone's move.** The first launch of a build pointed at the deployed Worker hands the phone's data to the
  account that signs in, and uploads it. It is rehearsed with a copy of the phone's store
  (`scripts/server-move-check.sh`). Back up the phone first, and deploy the Worker before or with that build.

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
No MEDIUM/LOW findings needed a separate backlog file — the reviews didn't surface any that
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

- **The deploy** — creating the Worker, D1 and the three R2 buckets per `docs/cloudflare-checklist.md`, each step
  approved separately, and deciding when the phone moves to it. Before it: the custom domain the owner chose,
  `https://api.gymrollins.com`, with its per-IP rate-limiting rules (the checklist's section 1, option A), and the
  caps plan 31 left open (section 5).
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

**Device sync caveat (documented, not tested on device):** `Base.xcconfig` defaults `API_URL` to
`http://127.0.0.1:8787` (the Mac's local Worker), overridden only by `Local.xcconfig`. A build installed on a
physical iPhone resolves `127.0.0.1` to the *phone itself*, so sync fails and the app works offline, as in airplane
mode (SwiftData is the source of truth). Don't point the owner's phone at any server before the cutover
(`docs/cloudflare-checklist.md`): the first launch with a new `API_URL` runs the server move. For a test phone
against the Mac, run the Worker on the LAN (`npx wrangler dev --local --ip 0.0.0.0 --var
PUBLIC_BASE_URL:http://127.0.0.1:8787 --infer-origin-from-routes=false` in `server/`: `wrangler.jsonc` holds the
deployed Worker's values, so a local start passes its own) and set
`API_URL = http:/$()/<Mac's LAN IP>:8787` in `Local.xcconfig` (the split `$()` keeps xcconfig from reading `//` as
a comment); `NSAllowsLocalNetworking` already allows plain http on the local network.

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
   logging workouts). For sync against your Mac's local Worker, see "Device sync caveat" above; for the deployed
   Worker, `docs/cloudflare-checklist.md` (back up the phone first).
5. Onboard with Sign in with Apple (or, in a DEBUG build, email/password), import your Fitbod
   export if you have one, and set up your profile.
