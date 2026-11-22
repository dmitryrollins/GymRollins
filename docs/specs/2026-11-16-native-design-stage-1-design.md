# Native design, stage 1: the Fitness look everywhere, and a workout's Apple Health data

Approved by the owner on 2026-11-16, section by section. Builds on Apple Health activities (plan 39,
`docs/specs/2026-11-16-health-activities-design.md`, whose §4.1 introduced the Fitness look for outside workouts), the
watch app (plan 17), the Cloudflare backend (`docs/specs/2026-11-07-cloudflare-backend-design.md`) and AI agents
(`docs/specs/2026-11-09-ai-agents-design.md`). Branch `feat-native-design`, from `feat-health-activities` df13a83.

## 1. Why

Plan 39 drew outside workouts in Apple Fitness' style, and the owner wants the whole app closer to Apple's own apps.
The rest of the app still uses its first look (`docs/design/STYLE.md`): a condensed italic display face (Barlow), a
coral accent, custom greys and uppercase letter-spaced labels. Next to plan 39's screens it reads as two apps.

The owner also wants a GymRollins workout to show what Apple Fitness shows for it: workout time, active and total
calories, heart rate, a heart-rate chart, post-workout heart rate and effort. The GymRollins watch app already records
a real HealthKit workout session, so Health has all of it, but the app shows only its own calorie estimate. Plan 39's
"Apple Watch measured" block appears only when a separate recording (Apple's Workout app) overlaps the session, because
plan 39 deliberately never imports GymRollins' own copies.

The redesign comes in stages, each with its own spec and plan:

1. **This stage:** the new look in the shared design pieces (every screen changes at once), and the workout detail
   rebuilt in full with its Health data.
2. The four tabs: Today, Body, Library, Log.
3. The live workout and its sheets.
4. The rest: Settings, onboarding, Gyms, sharing, Claude.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| 1 | **Fitness-native, dark only.** SF Pro text and titles, SF Rounded numbers, Apple's dark system colours, Fitness-style cards. The app stays dark-only. | Owner's choice ("Fitness-native, dark (Recommended)"). Light mode would mean every screen and the contrast audit twice. |
| 2 | **Accent: Fitness green-yellow `#B6F23A`** for buttons, links, toggles and the selected tab, with **black** text on filled buttons.<br>**Amended 2026-11-17, owner:** action buttons back to the red action colour the app had (coral `#FF6B72` accent, red `#C22F3B` / `#A82431` fills with **white** text); the green-yellow stays a data colour (`Theme.Metric.workout`). | Owner's choice ("Fitness green-yellow (Recommended)"). Coral `#FF6B72` sits next to the heart-rate red `#FF6961` and calories pink `#FF4F6D`, so coral buttons and links read as data. It is already plan 39's `Theme.Metric.workout`. |
| 3 | **Liquid Glass stays on every control, unchanged** in material, shape, size and placement. The only glass change is colour: the prominent tint went coral → green-yellow, and back to the app's red with decision 2's amendment (2026-11-17); accent text and icons on glass follow. | Owner: keep Liquid Glass wherever possible and change it as little as possible. |
| 4 | **Content stays solid**: cards, grids, charts and lists, now on Apple's dark greys with Fitness' larger corner radius. | As in `STYLE.md` (content solid, controls glass) and in Fitness. |
| 5 | **Rollout: swap the shared pieces first, then rebuild area by area.** Stage 1 changes `Theme`, `DisplayTitle`, `SectionLabel`, `SolidCard`, `Badge` and the glass buttons, so every screen switches at once; later stages restructure each area. | Owner's choice ("Swap everywhere, then rebuild (Recommended)"). The app never looks half old, half new. |
| 6 | The **workout detail** is stage 1's rebuilt screen, in Fitness' layout. | The owner asked for Fitness' data on GymRollins workouts; it is the screen that shows it. |
| 7 | The detail shows **Workout Time, Active and Total Calories, Avg. and Max Heart Rate, a Heart Rate chart, Post-Workout Heart Rate, and Effort (read and rate)**. | Owner's choice (all four options). |
| 8 | **Calories and Health's workout time count as measured only from the GymRollins watch app's recording, or from an attached recording (plan 39 rule 6).** A copy the phone wrote holds the app's own estimate and is never shown as measured. | The phone's exporter writes the estimate as an active-energy sample (`HealthKitStore.save(workout:)`); reading it back as "measured" would be false. |
| 9 | **Heart rate comes from every reading in the workout's time span, whatever recorded it.** | As in Fitness: a Watch worn during a phone-only workout still leaves readings. |
| 10 | **Effort: a rating in Health wins.** The workout also keeps its own effort, so rating works with Health off, and that copy is what syncs. A GymRollins rating writes to Health, replacing GymRollins' earlier one. | Health is where Fitness and the Watch rate and estimate effort; the app's copy serves Health-off use and the cloud. |
| 11 | **The summary numbers sync to the cloud and agents see them; heart-rate readings stay in Health** and the charts read them on the phone. | Owner's choice ("Numbers to cloud, chart stays (Recommended)"). Hundreds of readings per workout would dominate storage and sync for little agent value. |
| 12 | The numbers live in a **new table `workout_measurements`**, one row per workout, not in new `workouts` columns. | Builds 1–4 push workouts without the new fields; new columns would be wiped whenever an older build edits a workout. A separate table is invisible to them. |
| 13 | Agents' access follows plan 39's **"Read activity from Apple Health"** switch (on by default). | It is already the switch for Health data to agents. |
| 14 | **Not in stage 1:** system large-title navigation bars and native grouped lists (stages 2–4), light mode, an effort prompt at Finish, heart-rate zones, effort or measured calories in `get_training_summary` / `get_training_insights`. | Scope. |

## 3. The design system (whole app)

Every change lands in `ios/GymRollins/DesignSystem/`. Screens are not edited in this stage except the workout detail
(§4) and where a screen hard-codes something §3 removes (a `Theme.display` number, an uppercase label a test reads).

### 3.1 Colours (`Theme`)

| Token | Now | Stage 1 | Note |
|---|---|---|---|
| `background` | `0x0B0B10` | black `0x000000` | Fitness' page. |
| `card` | `0x17171E` | `0x1C1C1E` | Apple's dark secondary grouped background. |
| `cardInner` | `0x262631` | `0x2C2C2E` | Apple's dark tertiary grouped background. |
| `divider` | `0x25252E` | `0x38383A` | Apple's opaque dark separator. |
| `textPrimary` | `0xF2F2F5` | white | |
| `textSecondary` | `0xA9A9B5` | system `secondaryLabel` | 60 % `0xEBEBF5`; above 6:1 on `card`. |
| `textTertiary` | `0x8E8E9A` | `0x8E8E93` (system gray) | Not `tertiaryLabel`: its 30 % is under 4.5:1 and fails the audit. |
| `accent` | `0xFF6B72` | `0xFF6B72` (`0xB6F23A` until 2026-11-17) | Decision 2, amended: tints, links, toggles, the selected tab, accent text and icons. 7.6:1 on `background`, 6.2:1 on `card`, 5.0:1 on `cardInner`; white on it is 2.8:1, so nothing white sits on it. |
| `primaryFill`, `primaryButtonFill` | `0xC22F3B`, `0xA82431` | `0xC22F3B`, `0xA82431` (`0xB6F23A` until 2026-11-17) | A solid red fill (a chosen chip) and the prominent glass tint; the label on them is white, 5.6:1 and 7.1:1. |
| `onAccent` | white | white (black until 2026-11-17) | The label on `primaryFill` and `primaryButtonFill`; never used on `accent`. |
| `success`, `successFill` | `0x4FD1A5`, `0x14342A` | unchanged | "+5 lb", done sets. |
| `record` | `0xF5B75A` | unchanged | Records, warnings. |
| `destructive` | `0xFF8A8F` | system red (`0xFF453A` in dark) | Apple's destructive colour. |
| `Theme.Metric.*` | plan 39 | unchanged | Each re-checked against the new `card`; every one must stay at 4.5:1 or more (plan 39 tuned them on `0x17171E`). |

The tab bar takes the accent (`.tint`). Text on a red action fill (`primaryFill`, `primaryButtonFill`) is white
(`onAccent`), and nothing white or text-bearing sits on the coral `accent` (decision 2's amendment, 2026-11-17).

### 3.2 Type

- **Barlow goes**: `BarlowCondensed-BoldItalic.ttf`, `BarlowCondensed-ExtraBoldItalic.ttf` and `OFL.txt` leave
  `Resources/Fonts`, their `project.yml` entries go, and so does their entry in `Resources/CREDITS.md`.
- **Titles** (`DisplayTitle`, and `Theme.display` where it draws a title): SF Pro **bold** at the Dynamic Type text
  style `Theme.textStyle(forSize:)` already picks for the old size (44 → large title 34 pt, 28 → title 28 pt, 22 →
  title2 22 pt), so they keep scaling with Dynamic Type. Condensed 44 pt and SF Pro 34 pt are of similar width.
- **Big numbers** drawn in the old display face (stat tiles, set weights): SF Rounded **semibold**, as plan 39's
  `MetricSize` fonts. `Theme` gets a `number(_:)` font beside `display(_:)` for them.
- **Section labels** (`SectionLabel`): sentence case, no letter-spacing, subheadline semibold in `textSecondary`, as in
  iOS 26 Settings and Fitness. UI tests that match an uppercased label text change with it.

### 3.3 Shapes and controls

- `Theme.cardRadius` 18 → **24**; `SolidCard` padding 12 → **16**.
- On screens rebuilt in Fitness' layout (the workout detail in stage 1), section headers sit **above** the card in bold
  (title3), not inside it.
- Glass controls are unchanged (decision 3): `PrimaryGlassButton` keeps `.glassProminent` with the red action tint
  (`primaryButtonFill`) and a white label (decision 2's amendment, 2026-11-17); `GlassPillButton`,
  `SecondaryGlassButton`, `glassCircle()`, `glassCapsule()`, the tab bar, toolbars, the rest timer bar and every sheet
  keep their glass.
- `Badge` keeps its kinds; only its colours follow §3.1.
- Accessibility identifiers don't change, except on the workout detail (§4).

## 4. The workout detail

`Features/Log/WorkoutDetailView.swift`, pushed from a Log card. Top to bottom (sample values):

```
‹                          ⬆  ⋯      glass circles: Back · Share · Edit/Delete
(🏋) Push + Biceps                   strength symbol in a workoutFill circle (MetricIcon); SF Pro bold title
58:20                                headline: workout time, green-yellow, SF Rounded
Sat 19 Sep 2026, 14:00–14:58
⌚ Apple Watch                       what recorded it: Apple Watch, Apple Workout, or iPhone

Workout Details
╭──────────────────────────────╮
│ Workout Time    Active Cal.  │    time yellow, calories pink
│ 0:58:20         412KCAL      │
│ Total Cal.      Avg. HR      │    heart rate red
│ 489KCAL         128BPM       │
│ Max HR                       │
│ 162BPM                       │
╰──────────────────────────────╯
Measured by Apple Watch · Saved to Apple Health

Effort                               "6 Moderate" / "5 Moderate · Estimated" / glass ⊕ Add Effort
Heart Rate                           dot chart, max top-right, "128 BPM AVG"
Post-Workout Heart Rate              dot chart: end, 1 MIN, 2 MIN; last reading
Strength                             Exercises · Sets · Volume · Records (amber)
Exercises                            one card per exercise with its sets
```

- **Top bar:** glass back circle; on the right a glass **Share** circle (`square.and.arrow.up`, the existing plain-text
  recap) and the glass **⋯** (Edit / Delete, as now). The bottom Share bar goes. Editing keeps Cancel / Save and editing
  sets and "Reps left?" ratings as now. The "Added by …" line for an agent-logged workout stays under the date.
- **Workout Details** is a `MetricGrid` (plan 39's pieces): Workout Time, Active Calories, Total Calories, Avg. Heart
  Rate, Max Heart Rate. The footnote under it says what measured it and keeps today's Apple Health save status.
- **Nothing measured** (§5.3): the grid shows "Calories ≈ 277 KCAL (estimated)" with today's ⓘ explanation; Total
  Calories is hidden; Workout Time is the app's own duration; the footnote says "Estimated from your sets and body
  weight".
- **Heart rate** tiles and both charts appear only when Health has readings for them.
- **Attached recording** (plan 39 rule 6): its numbers fill the grid ("Measured by Apple Workout"); plan 39's separate
  `MeasuredActivityBlock` leaves this screen.
- **Effort card:** the rating as a number and its word, "· Estimated" for the Watch's estimate, or a glass **Add
  Effort** pill. Tapping the value or the pill opens the **Effort sheet** (glass, like the plate calculator): a 1–10
  scale with **Easy (1–3), Moderate (4–6), Hard (7–8), All Out (9–10)**, Save and Cancel, and "Clear" when GymRollins
  rated it.
- **Heart Rate chart** (Swift Charts, point marks in `heartRate` red): x = the workout's start to end with three time
  labels, the maximum labelled top-right, the caption "N BPM AVG" in red.
- **Post-Workout Heart Rate chart:** the end to 3 minutes after, labels at the end time, "1 MIN" and "2 MIN", the
  caption is the last reading ("124 BPM"). Hidden with no reading in that window.
- **Strength** grid: Exercises, Sets, Volume (numbers in primary), Records (amber). Today's Duration tile becomes
  Workout Time above.
- **Exercises:** one solid card per exercise with its sets, as now, in the new type.
- **Loading:** the app's own values draw at once; Health's numbers and charts fill in when the read finishes (usually
  well under a second). No spinner; cards don't jump (charts reserve their height once readings are known to exist).
- **VoiceOver:** each tile is one element ("Avg. Heart Rate, 128 beats per minute", plan 39's `MetricCell`). Each chart
  is one element with a summary ("Heart rate 14:00 to 14:58: average 128, maximum 162") and Swift Charts' audio graph.
- **Identifiers:** new `detail.workoutTime`, `detail.activeKcal`, `detail.totalKcal`, `detail.avgHeartRate`,
  `detail.maxHeartRate`, `detail.effort`, `detail.addEffort`, `detail.heartRateChart`, `detail.postHeartRateChart`,
  `detail.sets`; the Effort sheet's `effort.score.<1…10>`, `effort.save`, `effort.clear`. Kept: `detail.back`,
  `detail.menu`, `detail.cancel`, `detail.save`, `detail.addedBy`, `detail.share` (now the top-bar circle; used by
  `FlowCoverageUITests`), `detail.exercises`, `detail.volume`, `detail.records`, `detail.set.*`. Gone:
  `detail.duration` (no test reads it) and plan 39's `detail.measured.*`, whose `HealthActivityUITests` case moves to
  the grid's identifiers.

## 5. Apple Health on the phone

### 5.1 Reading (`GymHealth`)

`HealthStore` gets `workoutMeasurements(externalId:start:end:)` (with `FakeHealthStore`), answering a
`WorkoutMeasurements`:

| Field | From |
|---|---|
| `recordedBy` | The GymRollins copy found by `HKMetadataKeyExternalUUID`: **watch** when it carries `WatchHealthRules.writerKey == watchWriter`, **phone** when it is the exporter's copy, nil with no copy. |
| `duration` | The watch copy's `HKWorkout.duration` (pauses excluded). Nil otherwise. |
| `activeKcal`, `totalKcal` | The watch copy's statistics for active energy, and active + resting (basal) energy. Nil otherwise (decision 8). |
| `heartRate` | Every heart-rate sample from `start` to `end`, any source (decision 9), as (date, bpm), plus their average and maximum. |
| `postWorkout` | Heart-rate samples from `end` to `end` + 3 min, and the last one. |
| `effort` | The workout effort score related to the copy (rated), else the estimated effort score, with which it is. Nil with no copy or neither. |

`rateEffort(externalId:score:)` saves a workout effort score sample (1–10) and relates it to the copy, after removing
GymRollins' earlier one; `clearEffort(externalId:)` removes GymRollins' own. Exact HealthKit API names (iOS 18's effort
types and relationship query) are checked against the iOS 26 SDK in the plan.

### 5.2 Permissions

Plan 39's activity read already covers heart rate and active and resting energy. Added to the same single request:
the workout effort score (read and write) and the estimated workout effort score (read). If the owner already allowed
plan 39's types, the Effort card shows one glass **Allow** pill until the new types have been asked (iOS asks only about
new types). Denied: ratings stay in the app (§5.4) and nothing is written to Health.

### 5.3 What the detail shows (one pure rule)

`WorkoutMeasuredRules.summary(workout:measurements:attached:estimate:)` in GymCore decides each value, whether it is
measured or estimated, the "recorded by" line, and which cards show. Order: the **watch copy**, then the **attached
recording**, then the **app's estimate**. Heart rate comes from `measurements.heartRate` whatever the order picked.
Effort: Health's rating, else the app's own rating, else Health's estimate. Unit-tested on its own.

### 5.4 Effort in the app

`Workout` gets an optional effort (1–10, `effortEstimated` false) in its measurement record (§6). Rating in GymRollins
writes the record and, when allowed, Health. Opening the detail adopts Health's rating when it differs (a rating made
in Fitness). A failed Health write keeps the app's rating and shows "Couldn't save to Apple Health" under the card.

### 5.5 When it reads and saves

- Every time a workout's detail opens (cached for the session per workout).
- Once after a workout finishes: when the watch reports `healthRecorded`, or when the phone's export completes.
- When plan 39's import attaches or removes an outside workout overlapping a GymRollins workout.
- Once after the new permission is granted, for workouts from the last 90 days. Older workouts get theirs when first
  opened.

Each read that changes the shown numbers saves them to the workout's measurement record (§6).

### 5.6 Failures and Health off

A failed read shows the app's values and logs the error; it never blocks the screen. With Health off, or on a device
without Health: the app's values, no charts, Effort still rateable and stored in the app.

## 6. Data and server

### 6.1 `workout_measurements` (migration `0014_workout_measurements.sql`)

One row per workout, primary key (`user_id`, `workout_id`), the workout's row referenced with `ON DELETE CASCADE`.

| Column | Type | Rule |
|---|---|---|
| `workout_id` | text | 36 chars. |
| `recorded_by` | text, nullable | `watch` or `apple_workout`; null when only heart rate or effort is known. |
| `duration_s` | real, nullable | 0–86 400. |
| `active_kcal`, `total_kcal` | real, nullable | 0–20 000 (as 0013). |
| `avg_hr`, `max_hr` | integer, nullable | 20–250. |
| `post_hr` | integer, nullable | 20–250: the reading closest to 2 minutes after the end (the card shows the last reading; the stored value is a steady recovery measure). |
| `effort` | integer, nullable | 1–10. |
| `effort_estimated` | integer | 0 or 1. |
| `client_updated_at`, `updated_at`, `deleted_at` | text | As 0013's timestamp checks. |

Additive only. Its row count is bounded by `workouts`, so no extra cap trigger.

### 6.2 Sync

A new entity `workout-measurements` at `/v1/sync/workout-measurements` in `server/src/sync/entities.ts`, like plan 39's
`health-activities`: last write wins by the device's edit time; other accounts' rows refused. In the app: a GymData
model linked by workout id, and GymSync pushes and pulls it after workouts. Heart-rate readings are never stored
(decision 11).

### 6.3 Agents (MCP)

- `get_workout` gains a **Measured** part: "Apple Watch: 58 min, 412 active kcal (489 total), heart rate avg 128 / max
  162, 124 BPM 2 min after, effort 6/10 Moderate". With nothing measured, the text stays as today (the server has
  never shown the app's calorie estimate). Effort alone: "Effort 6/10 Moderate".
- `list_workouts` adds active kcal, average heart rate and effort to each line that has them.
- Both read the measurements only when the profile's `mcp_read_activity` is on (decision 13).
- `get_training_summary`, `get_training_insights` and `log_workout` don't change.
- A drift test keeps the app's limits and the server's checks equal, as plan 39's.

## 7. Rollout

1. With the owner's approval: a D1 time-travel bookmark, migration 0014, then the Worker deploy.
2. Then build 5 to TestFlight, asked before upload.

Builds 1–4 keep working against the new server (they never call the new route). Build 5 against the old server gets a
404 on the new route, which ends each sync round early, which is why the server goes first.

Privacy: effort and heart-rate summaries join the Health data already pending from plan 39; the privacy policy and the
App Store privacy answers cover them before release.

## 8. Testing

- **GymCore:** `WorkoutMeasuredRules` (watch copy > attached > estimate; estimate-only; Health off; no readings; hidden
  cards; effort order); the effort scale and words; chart shaping (readings inside the workout only, the 3-minute
  window, max label, average, three time ticks).
- **GymHealth:** `workoutMeasurements`, `rateEffort` and `clearEffort` through `FakeHealthStore`, including "a phone
  copy is never measured" and "a watch copy is".
- **GymData / GymSync:** the model, push and pull order after workouts, conflicts.
- **Server:** migration 0014's checks; the route (ranges, other users refused, cascade on workout delete); the
  `get_workout` and `list_workouts` text with the switch on and off; the drift test.
- **UI:** the detail's identifiers in the measured, estimate-only and Health-off versions; rating, changing and
  clearing effort; accessibility text sizes. Every existing UI suite still passes after the swap. The accessibility
  audit passes on every screen, with `AccessibilityAuditUITests.agentSwitchLabels` gaining plan 39's "Read activity from
  Apple Health" label and footer (the known `testAgentsAudit` flake).
- **Screenshots for the owner before any merge:** Today, Body, Library, Log, the live workout, one sheet, Settings, and
  the new detail measured, estimate-only and at an accessibility text size, before and after.
- **On physical devices with build 5:** a GymRollins watch workout shows Fitness' numbers; an effort rated in
  GymRollins shows in Fitness and the other way round; Claude's `get_workout` shows the measured part.

Done: packages, server and the whole app suite green on the final commit (the 5 known `SharedWorkoutUITests` link
failures aside); the privacy scan clean; pushed with a PR to `feat-health-activities` (main once PR #8 merges), not
merged without the owner.
