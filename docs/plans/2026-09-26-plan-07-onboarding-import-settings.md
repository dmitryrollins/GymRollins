# Plan 07: Onboarding, Fitbod CSV import, Settings, first-run states

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new install walks through Welcome → Profile → Import CSV → Import result (match unknown exercises) →
Connect Claude → Today. The owner's full Fitbod export imports with every exercise matched. Settings covers units,
rest, bar/plates, progression, Claude, import/export, account deletion and credits, and first-run empty states are
handled.

**Architecture:** `ImportService` (`@MainActor`, app) orchestrates GymCore `FitbodImporter` + `ExerciseMatcher` +
a curated alias table (`Resources/fitbod-aliases.json`), then saves through `WorkoutRepository` (source `.import`;
workout ids from the importer make re-import idempotent). A pure `ImportPlan` value (matched/unmatched/stats) drives
the UI and is unit-tested. `ExportService` produces a JSON backup (all aggregates) and a Fitbod-format CSV (so data
can round-trip). Onboarding state lives in `UserDefaults` (`onboardingComplete`), and UI tests control it with
launch flags.

**Tech Stack:** SwiftUI iOS 26 (`fileImporter`, `ShareLink`, `SignInWithAppleButton`), GymCore, GymData, GymSync,
Swift Testing, XCUITest.

**Depends on:** Plans 03–06 merged. **Mockups:** `Welcome`, `ProfileSetup`, `ImportCSV`, `ImportResult`,
`ConnectClaude`, `Settings`, `SyncStates`, `CustomExercise`.

**Conventions:** Branch `plan-07-onboarding-import-settings`. Commit per task with the trailer lines. Never
`git add -A`. **Personal data:** the owner's real export (`<a folder outside the repo>/WorkoutExport.csv`)
may be *read* locally to build and check the alias table, but it must never be copied into the repo. Test fixtures
use small synthetic or trimmed rows (exercise names and numbers only, no notes).

---

### Task 1: Fitbod alias table from the owner's exercise names

**Files:** `scripts/fitbod-alias-report.mjs`, `ios/GymRollins/Resources/fitbod-aliases.json`,
`docs/import/fitbod-alias-review.md`.

- [ ] `fitbod-alias-report.mjs <csv>`: reads the CSV locally, collects the distinct exercise names with their set
  counts, runs the same normalization and Jaccard matching as GymCore `ExerciseMatcher` against `exercises.json`
  (port the ~40 lines of logic), and prints a markdown table: Fitbod name, count, best match id + name, score, and
  runner-up. It writes nothing into the repo except when called with `--out docs/import/fitbod-alias-review.md` (the
  names and counts only).
- [ ] Curate `fitbod-aliases.json`: `{ "<Fitbod name>": "<library id>" | null }` for **every** distinct name in the
  owner's export. Use the report plus judgment (e.g. "Lat Pulldown" → `0198` cable pulldown, "Cable Face Pull" →
  `0203`, "Machine Shoulder Press" → `0603`, "Ab Crunch Machine" → the lever/machine crunch id, "Walking" → the
  walking cardio id). `null` means "create a custom exercise on import" (Handle Band movements, Clam, Glute Ham
  Raise if absent…). Record each decision in the review doc (name → id → why).
- [ ] Test (`GymRollinsTests/AliasTableTests.swift`): every value in the JSON is either null or an id that exists in
  `exercises.json`, and there are no duplicate keys after normalization.
- [ ] **Commit:** `feat(import): curated Fitbod alias table with review notes`

---

### Task 2: ImportService and ImportPlan

**Files:** `Features/Import/ImportPlan.swift`, `Features/Import/ImportService.swift`; Tests `ImportPlanTests.swift`,
`ImportServiceTests.swift`; fixture `GymRollinsTests/Fixtures/fitbod-sample.csv` (≈30 synthetic rows: 3 workouts,
a warm-up, a cardio row, an unknown exercise, one bad row).

- `ImportPlan.make(result: FitbodImportResult, library: ExerciseLibrary, aliases: [String: String?], matcher: ExerciseMatcher) -> ImportPlan`:
  - resolution order per distinct name: alias table (if the key exists: a non-null id → matched; null → custom),
    then matcher exact/alias, then fuzzy (≥ 0.6 and unambiguous) → **suggested** (needs confirmation), else
    unmatched;
  - stats: workouts, sets, warm-up sets, date range, row errors;
  - `resolved(name) -> Resolution` (`.library(id)`, `.custom`, `.needsChoice(suggestion: String?)`).
- `ImportService.importAll(plan:choices:)`: creates custom exercises for `.custom` names (`CustomExerciseRepository.create`,
  mode `.cardio` when any of its sets has duration/distance and no reps), maps every imported workout to a GymCore
  `Workout` (entries in order; `WorkoutSet(weightKg:reps:sec:distanceM:done: true, warmup:, multiplier:, completedAt: startedAt)`;
  `endedAt` = startedAt + (sum of set durations, or 45 min if unknown). **Stated here:** Fitbod's export has no
  session duration, so imported durations are approximate and marked `note = "Imported from Fitbod"`), and saves via
  `WorkoutRepository.save` (a re-import overwrites the same ids with no duplicates). Returns `ImportSummary`. Runs in
  batches of 20 workouts with `Task.yield()` between batches, and reports progress 0…1.
- Tests: the fixture plan has the right counts and resolutions; importing twice leaves the same number of workouts;
  cardio rows become cardio sets; the warm-up flag is preserved; the bad row is reported (line number); custom
  exercises are created once.
- **Commit:** `feat(import): import plan resolution and idempotent import service`

---

### Task 3: Onboarding flow

**Files:** `Features/Onboarding/OnboardingFlow.swift` (router), `WelcomeView.swift`, `ProfileSetupView.swift`,
`ImportCSVView.swift`, `ImportResultView.swift`, `ConnectClaudeStepView.swift`; modify `App/RootView.swift`,
`App/LaunchOptions.swift` (`-onboarding` forces the flow, `-skipOnboarding` marks it complete; `-uiTesting` defaults
to skip so existing tests keep working).

- **Welcome** (`onboarding.welcome`): display title "GymRollins", value prop, `SignInWithAppleButton` (real flow via
  `AuthService.signInWithApple`), a DEBUG "Continue with email" (`onboarding.email`) → a sheet with the plan 05 email
  form, and "Skip for now" (`onboarding.skip`; local-only mode, sign in later from Settings).
- **ProfileSetup** (step 1/3, glass progress dots): units segmented (`setup.units`), height, bodyweight (also saved
  as the first weigh-in), goal weight + date, training days (2–6 segmented), experience, limits text. Validation
  uses the same ranges as the DB. "Continue" `setup.continue` saves the Profile (and weigh-in).
- **ImportCSV** (step 2/3): cards "Import CSV from another app" (`import.choose` → `.fileImporter` for
  `.commaSeparatedText`) and "Start fresh" (`import.skip`). After picking a file, show the file name + row count and
  the column-mapping preview (a static table from `FitbodImporter.expectedHeader` → destination, with ignored columns
  in tertiary color), then "Import" `import.run` with a progress bar. Errors: a wrong header shows "This doesn't look
  like a Fitbod export. Expected columns: …" and stays on the step.
- **ImportResult**: a success check, "N workouts · N sets · <date range>", "N exercises matched", then "N need a
  match" with each row → a picker (library search reusing `ExercisePickerView` in single-select mode, or "Create as
  custom exercise"). Rows are `result.match.<index>`. "N warm-up sets kept". "Continue" `result.continue` is enabled
  once every name is resolved.
- **ConnectClaude** (step 3/3): reuse the connector URL/steps/permissions from `ClaudeConnectionView` (extract a
  shared `ConnectorInstructions` view). "Done" `onboarding.done` and "Later" `onboarding.later` both finish.
- On finish: `onboardingComplete = true`, and if there's no routine, offer to create the owner's split from a
  template ("Push / Pull / Upper / Legs" template = the `OwnerSeed` routines with no history) or start empty.
- **UI test** `OnboardingUITests.testFullOnboardingWithImport`: launch `-uiTesting -onboarding -importFixture` (the
  DEBUG flag makes the file importer return the bundled test fixture URL instead of presenting the system picker,
  since XCUITest can't drive the Files UI reliably). Walk every step, resolve the unknown exercise by creating it as
  custom, finish, and check that Today shows, and that Log shows 3 imported workouts.
- **Commit:** `feat(onboarding): welcome, profile setup, CSV import with matching, Claude step`

---

### Task 4: Settings

**Files:** `Features/Settings/SettingsView.swift`, `BarAndPlatesView.swift`, `CreditsView.swift`,
`Features/Export/ExportService.swift` (+ tests); modify `LogView` (the gear → Settings), `TodayView` (the avatar →
Settings); fold `AccountView` into the Settings Account section.

Grouped solid list (mockup `Settings.dc.html`), with identifiers `settings.<row>`:
- **Account:** the signed-in email or "Not signed in" (sign in → the Welcome sign-in sheet), Sync status + "Sync
  now", Sign out.
- **Training:** Units (lb/kg; changing it converts the plate inventory display, since storage is kg), Default rest
  (working / warm-up), Bar & plates (editor: bar weight, available plates with toggles for 45/35/25/10/5/2.5 lb or
  25/20/15/10/5/2.5/1.25 kg, dumbbell step), Warm-up sets on/off (`@AppStorage("autoWarmups")`, read by
  `SessionPlanner` via the environment), Default progression (policy for new routines), Deload % (2.5–10).
- **Claude:** → `ClaudeConnectionView` (with a "Connected"/"Not connected" badge).
- **Data:** Import CSV (reuses the onboarding import steps as a pushed flow), Export all data → `ShareLink` with
  the JSON backup file, Export CSV (Fitbod format) → `ShareLink`.
- **Privacy:** Privacy policy (in-app text page, a plain-language summary: data on device + your account, Claude
  sees only what you allow, no ads/tracking), "Delete account and data" (signed in: the plan 05 RPC + local wipe;
  signed out: "Erase all data on this iPhone"), both with typed-DELETE confirmation.
- **About:** version/build, `CreditsView` (renders `Resources/CREDITS.md`, exercise data MIT notice, font OFL),
  open-source notices.
- `ExportService` tests: the JSON round trip (export → decode → the same counts), and the CSV header equals
  `FitbodImporter.expectedHeader` and re-imports to the same workouts (round trip through `FitbodImporter`).
- UI tests `SettingsUITests`: switching units to kg makes Today show "63.5 kg (140 lb)" style; the plates editor
  change reflects in the plate calculator; Export shows the share sheet; "Erase all data on this iPhone" returns to
  onboarding.
- **Commit:** `feat(settings): account, training prefs, bar/plates, Claude, import/export, privacy, credits`

---

### Task 5: First-run and empty states

- Today with no routines: "No plan yet" with "Create a routine" (→ RoutineEdit with a new routine) and "Ask Claude
  to build one" (→ the Claude connection screen, with a copyable prompt such as "Build me a 4-day upper/lower plan
  using get_profile and propose_plan_changes").
- Log empty: "No workouts yet — Start your first workout or import a CSV" with both actions. Body empty is already
  done in plan 04.
- Library search with no results: "No exercises match '<q>'" plus "Create '<q>' as a custom exercise".
- UI test: launch `-uiTesting -skipOnboarding -emptyStore` (a new flag: no seed) → verify each empty state and
  its primary action.
- **Commit:** `feat(app): first-run empty states`

---

### Task 6: Verify, review, merge

- [ ] **Real-data dry run (local only):** run a DEBUG-only unit test `RealExportImportTests` that is skipped unless
  the env var `GYM_REAL_EXPORT` points to the owner's CSV. It builds the ImportPlan and asserts 0 unresolved names
  and the expected counts (142 workouts, 0 row errors, 185 warm-up sets), then imports into an in-memory store
  (must finish in < 5 s). Run it once with the env var set, record the numbers in the PR/merge message, and never
  commit the CSV.
- [ ] `scripts/test-all.sh` green; swiftlint has 0 errors; `codex review --base main` → fix P0–P2.
- [ ] Screenshots of onboarding steps and Settings → `docs/screenshots/plan-07/`.
- [ ] Merge with `--no-ff`, then delete the branch.
