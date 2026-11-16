# Apple Health activities: workouts from other apps and daily activity

Approved by the owner on 2026-11-16. Builds on Apple Health (plan 15, `docs/plans/2026-09-30-plan-15-health.md`), the
watch app (plan 17), the Cloudflare backend (`docs/specs/2026-11-07-cloudflare-backend-design.md`) and AI agents
(`docs/specs/2026-11-09-ai-agents-design.md`).

## 1. Why

GymRollins writes its own workouts and weigh-ins to Apple Health and reads weight and body fat back, nothing else.
Walks, runs, rides, Fitness+ classes and Strava workouts recorded by the Apple Watch or other apps never reach the app,
and neither do steps or the Activity rings. The owner wants all of it in the app and in the cloud, so the agents can
plan around it (no heavy legs the day after a long run).

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| 1 | Two **new record kinds**: an **outside workout** (`HealthActivity`) and a **day of activity** (`ActivityDay`). Outside workouts are **not** `Workout`s. | `workouts.source` is CHECKed to `app`/`import` (a table rebuild to change); older builds read an unknown source as `app` and would export it back to Health and let it be edited; walks would flow into PRs, strength summaries, the `log_workout` overlap check and the 10,000-workout cap. |
| 2 | Import **every workout in Health that GymRollins didn't write**, from any source, plus **steps, move kcal, exercise minutes and stand hours per day**. | Owner's choice ("Workouts + daily activity"). |
| 3 | Both kinds **sync to the server** and agents read them through a new MCP tool **`get_activity`**. | Owner's choice ("Phone + cloud, agents see them"). |
| 4 | Agents' access sits behind a new switch **"Read activity from Apple Health"**, **on** by default. | Owner's choice. Health data to a third party needs the user's say-so; the switch is it. |
| 5 | Outside workouts **count toward the streak and the weekly workout goal** (app and MCP insights alike) when they last **10 minutes or more** and aren't attached to a GymRollins workout (rule 6). | Owner's choice ("any activity counts"); the 10-minute floor keeps an accidental 1-minute start from counting. |
| 6 | An outside workout that overlaps a GymRollins workout by **at least half of the shorter one** is **attached** to it: not listed or counted on its own; the GymRollins workout shows its measured kcal and heart rate. | Apple's Workout app recording "Strength" during a GymRollins session is the same session. |
| 7 | Two outside workouts of the **same kind** overlapping by **80 %** or more are one session: shown and counted once, the Apple Watch recording first, else the longer. Both stay stored. | Strava (or another app) re-saving a Watch run. Read-time rule, so data stays exactly what Health has. |
| 8 | Rules 6 and 7 are **computed when read**, by one pure Swift function and a TypeScript mirror tested against the same fixtures. | An attachment can appear later (a GymRollins workout logged afterwards, an agent's `log_workout`); storing it would go stale. |
| 9 | Outside workouts are **read-only** in GymRollins. Deleting one in Health deletes it here (and in the cloud). | Health is the source of truth for them. |
| 10 | The weekly "≈ N kcal this week (estimated)" line stays GymRollins-only. A second line shows "+ M kcal from other activities (measured)". Daily move kcal is never added to either. | Health's move total already includes GymRollins' exported estimate; adding them would double count. |
| 11 | Daily totals come from Health's merged statistics (steps) and Activity summaries (move, exercise, stand), never from summing raw samples. | Raw samples double count iPhone + Watch. |
| 12 | Import window: **2 years** on first import (as for weight). Afterwards: workouts incrementally (anchored query, deletions included); days **re-read for the last 7 days** on every sync, written only when a value changed. | Watch data lands late; a week covers it without re-pushing old days. |
| 13 | No background delivery: imports run when the app launches or comes to the foreground, after enabling, and after a cloud pull (as today). | YAGNI; the agents read the server, which is as fresh as the last app open. |
| 14 | Not in this plan: heart-rate graphs, routes and maps, sleep, editing outside workouts, adding them to the JSON/CSV exports, writing anything new to Health. | Scope. |
| 15 | Average power, average cadence and total calories are kept too (owner's choice 2026-11-16, after the Fitness summary of a LifeFitness ride); shown only when the workout has them. | An Indoor Cycle recorded by the Apple Watch with GymKit shows Avg. Power 138 W, Avg. Cadence 62 RPM, Active 40 kcal and Total 48 kcal in Apple Fitness. |

## 3. Data

### 3.1 Outside workout (`HealthActivity`)

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | The HealthKit workout's UUID: two devices of one account importing the same workout write the same row. Unique per account, not globally (one iPhone's Health can be read into two accounts). |
| `kind` | text | A stable slug mapped from `HKWorkoutActivityType` (`walking`, `running`, `cycling`, `hiit`, `yoga`, `swimming`, `traditional_strength`, `functional_strength`, `elliptical`, `rowing`, `hiking`, `dance`, `core`, `pilates`, `cooldown`, … `other`). Unknown types become `other`. |
| `startedAt`, `endedAt` | timestamps | |
| `durationS` | real | HealthKit's duration (pauses excluded). |
| `kcal` | real? | The workout's active energy statistic. |
| `totalKcal` | real? | Active plus resting energy (Apple Fitness's "Total"): `kcal` plus the workout's `basalEnergyBurned` sum. Nil when the resting energy (or the active) is missing, and nil when it would come out below `kcal`. |
| `distanceM` | real? | Walking/running, cycling or swimming distance, whichever the workout has. |
| `avgHr`, `maxHr` | int? | From the workout's heart-rate statistics. |
| `avgPowerW` | int? | Watts: the workout's average `cyclingPower`, else its average `runningPower`. Nil without either (no power meter, GymKit equipment or Watch run). |
| `avgCadenceRpm` | int? | The workout's average `cyclingCadence`, in revolutions per minute. Nil without it. |
| `sourceName` | text | The source's name as Health shows it ("Apple Watch", "Strava"). |
| `fromWatch` | bool | Recorded on an Apple Watch (device model), for rule 7. |
| `deletedAt` | timestamp? | Tombstone when it left Health. |

Not imported: workouts carrying GymRollins' own metadata (`GymRollinsExport`, `GymRollinsWriter`), workouts from the
app's or the watch app's bundle, workouts whose `HKMetadataKeyExternalUUID` is a GymRollins workout id.

### 3.2 Day of activity (`ActivityDay`)

Keyed by the **local calendar day** (`YYYY-MM-DD`) it was recorded in: `steps` (int), `moveKcal` (real),
`exerciseMin` (int), `standH` (int?; nil without a watch). A day with no data at all isn't stored.

### 3.3 Limits

Mirrored in `DomainLimits` (Swift) and `domain-limits.ts` (with the existing drift test), enforced by D1 CHECKs:
duration 0–24 h, kcal and total kcal 0–20,000, distance 0–1,000 km, heart rate 20–250, average power 0–2,500 W,
average cadence 0–250 rpm, steps 0–200,000, exercise 0–1,440 min, stand 0–24 h, kind and source name 1–100
characters. Nothing is clamped. An outside workout whose **optional** value (kcal, total kcal, distance, heart rate,
power, cadence) is outside its limit is imported without that value (nil); one whose required field (kind, source
name, start after end, duration) is outside is skipped. A day outside a limit is skipped.

## 4. Phone

- **Reading from Health.** `HealthStore` gains read methods: outside workouts changed since an anchor (added + deleted)
  and day totals for a date range. `HealthKitStore` asks to read step count, active and resting energy, exercise
  time, heart rate, the distance types, cycling and running power, cycling cadence and Activity summaries (besides
  what it reads now). Read types are **not** added to `HealthDataType` (that enum is the write list; its summary
  would never say "Connected" again).
- **State.** New `HealthSyncState` fields (activity anchor, import start, the two reading switches, whether the new
  permissions were asked) use the optional-storage pattern, so an old saved state still decodes. (A decode failure
  resets the whole state, which would turn Health off and drop the export ledgers.)
- **Permissions for people who already use Health.** The system asks only once per type, and today it only asks in
  `enable()`. With Health on and the new types never asked, Today shows a one-time card, "Bring in your Apple Watch
  activity", with **Allow** (asks Health, then imports) and **Not now**. Settings › Apple Health has the same ask.
- **Settings › Apple Health** gets a "Reading from Health" section: **Workouts from other apps** and **Steps &
  activity**, both on by default while Health is on. Turning one off stops that import and hides that data in the
  app; nothing already in the cloud is deleted. The section stays with Health off: nothing new is read then, but
  what was read before still shows, so its switch must still hide it.
- **Storage.** Two new SwiftData models and repositories in GymData; two new sync kinds (pushed after workouts),
  wired everywhere a kind is registered (store tracking, account reset, ownership, server move, debug transports,
  sync status names).
- **Log.** Outside workouts that aren't attached appear in the history between GymRollins workouts as compact
  read-only cards: kind icon, name ("Walk"; titles come from the kind, there's no indoor/outdoor field), date · duration, distance, kcal, source. A tap opens a detail
  screen with the same facts plus average/max heart rate and "Change or delete it in the Health app." The detail
  reloads when the app's data changes; once Health deleted the workout it says "This workout was removed from
  Health." Both are drawn in the look of §4.1. The week strip
  counts their minutes in a lighter shade. The kcal line follows decision 10.
- **GymRollins workout detail.** With an attached outside workout: what the Apple Watch measured (412 kcal, avg 128
  bpm, max 162 bpm) under the calorie card, as §4.1's measured block.
- **Today.** An Activity row with today's steps, move kcal and exercise minutes; a tap shows the last 7 days. Hidden
  when Steps & activity is off or there's no data for the last 7 days.
- **Streak and weekly goal** count outside workouts per decision 5.
- **Purpose string.** `NSHealthShareUsageDescription` says the app reads workouts from other apps, steps, activity
  and heart rate, besides weight and body fat.

### 4.1 Look: Apple Fitness style (owner's request, 2026-11-16)

The owner sent the Fitness app's Indoor Cycle summary and asked for the activity screens to look like it. The
screens it covers are:

- the outside-workout card in the Log;
- its detail;
- the measured block on a GymRollins workout;
- Today's Activity row;
- the 7-day sheet;
- the one-time permission card.

The rest of the app keeps its own look. The pieces live in `DesignSystem/MetricStyle.swift` (`Theme.Metric`,
`MetricValueText`, `MetricCell`, `MetricGrid`, `MetricRow`, `MetricIcon`), and `ActivityText` builds each value as a
`MetricReading` (key, label, value, unit, spoken text, colour token), so the formatting is unit-tested.

**Metrics are coloured by kind.** Each value is drawn in its metric's colour: SF Pro Rounded, semibold. Its unit
follows in the same colour, uppercase, about 60 % of the value's size, with no space ("2.26KM", "40KCAL", "138W",
"62RPM", "0:05:08"). Digits stay proportional, as in Fitness' summary: these values don't tick, and tabular digits
left a gap after every 1 ("1 38W"). The label above it is plain body text in `Theme.textPrimary` ("Workout Time",
"Active Calories").

Tokens are `Theme.Metric`. Every colour keeps at least 4.5:1 contrast on both `Theme.card` and `Theme.background`
(checked with a script; the lowest is `calories`, 5.6:1 on the card), so the accessibility audit passes even for the
small units.

| Token | Use | Value |
|---|---|---|
| `workout` | the kind icon and the headline metric (the list row's big number, the line under the detail title) | 0xB6F23A, Fitness' green-yellow |
| `workoutFill` | the round icon's fill, a dark tint of `workout` (10:1 with it) | 0x26330F |
| `time` | Workout Time | 0xF6E23B, yellow |
| `distance` | Distance | 0x40A8F5, blue |
| `calories` | Active Calories, Total Calories, Move | 0xFF4F6D, pink-red (Apple's 0xFA114F is under 4.5:1) |
| `heartRate` | Avg. / Max Heart Rate | 0xFF6961, coral red |
| `power` | Avg. Power | 0xB6F23A, green-yellow |
| `cadence` | Avg. Cadence | 0x5EE0E6, cyan |
| `steps` | Steps | 0xA98BFF, violet |
| `exercise` | Exercise | 0xA6F23A, ring green |
| `stand` | Stand | 0x3FE6EF, ring cyan |

**Units.** These are KM/MI (per the profile, two decimals as in Fitness), KCAL (not Apple's CAL: the app says kcal
everywhere), W, RPM, BPM, MIN and HRS. Time is H:MM:SS ("0:05:08"). Steps have no unit; the label says it.

For VoiceOver, each cell is one element whose label is the metric and whose value speaks the unit in full, for
example "Distance, 2.26 kilometres", "Active Calories, 40 kilocalories" or "Workout Time, 5 minutes 8 seconds".
Today's row and a day of the 7-day sheet read as one element ("Activity", "Steps 4,210, Move 210 kilocalories, …"),
and the Log card as one button ("Cycling, 2.26 kilometres, Thu 24 Sep, 5 min, LifeFitness"). Values use text styles
(`.system(.title, design: .rounded, weight: .semibold)` and smaller) so they scale with Dynamic Type. At accessibility
sizes the 2-column grids become 1 column.

**Detail (Fitness' summary).**

- The glass back button stays.
- Behind the header sits the kind's symbol, very large and faint (8 % white), like the big bike in Fitness. It has a
  fixed size: it's decoration.
- The title is the kind's name in large bold SF. Titles come from the kind, and the kind has no indoor/outdoor field,
  so the owner's ride reads "Cycling", not Fitness' "Indoor Cycle".
- Under it is the headline metric in `workout` colour: the distance, else active kcal, else the time.
- Under that, in secondary text, is the date and time range ("November 15, 2026, 16:02–16:07", in the phone's date
  and time format), and under it the source, after `applewatch` when it was recorded on a Watch. Fitness puts both on
  one line; here the source has its own, and the watch is its own element read "Apple Watch": inside the text, the
  symbol's spoken name made the line's label longer than the line, and the accessibility audit flagged it as clipped.
- A **"Workout Details"** header (title3 bold, no chevron: nothing opens from it) sits over one card holding a
  2-column grid, in Fitness' order:
  - Workout Time | Distance
  - Active Calories | Total Calories
  - Avg. Power | Avg. Cadence
  - Avg. Heart Rate | Max Heart Rate

  Missing values are left out and the grid flows on.
- The footnote "Change or delete it in the Health app." comes last.
- It reloads when the app's data changes. With the row gone or a tombstone, the screen shows "This workout was removed
  from Health." instead.

**Log card (Fitness' workout list row).**

- On the left, the kind icon in `workout` colour inside a 44 pt circle filled with `workoutFill`.
- Next to it, the kind's name in subheadline secondary, and under it the headline metric (title2 rounded, `workout`
  colour).
- On the right, the date ("Thu 24 Sep"), with the duration and source under it ("5 min · LifeFitness"), in footnote
  secondary. At accessibility sizes they go under the metric.
- It's still read-only and opens the detail. It no longer has the outline: the round icon sets it apart from a
  GymRollins workout.

**Measured block on a GymRollins workout.** A card under the calorie card: "Apple Watch measured" (the source's name,
with `applewatch` when a Watch recorded it) over a compact 2-column grid of the same cells: Active Calories, Avg.
Heart Rate, Max Heart Rate, plus Avg. Power when there is one.

**Today's Activity row.** It's a card titled "Activity" with a chevron. Below the title is one row of cells: Steps,
Move (KCAL), Exercise (MIN), and Stand (HRS) only when a Watch counted it. When the row doesn't fit whole (large text)
it becomes the 2-column grid, and 1 column at accessibility sizes. It hides as before.

**7-day sheet.** Each day is the date over the same row of cells, at a smaller size.

**Permission card.** It uses the round icon (`applewatch` in `workout` colour) instead of the plain label icon. Its
text and buttons stay the same.

**UI-test data.** `-fakeHealth` also seeds an Indoor Cycle shaped like the owner's ride (synthetic: LifeFitness,
recorded on a Watch, 5 min 8 s, 2,260 m, 40 of 48 kcal, 138 W, 62 rpm, avg 128 and max 151 bpm) on the Thursday
before `-fixedNow`. It's added in the app (`AppEnvironment.uiTestRide`), next to GymHealth's seed. Under 10 minutes, it
doesn't count toward the streak or the weekly goal; the week's measured kcal becomes 220.

## 5. Server

- **Migration `0013`**: tables `health_activities` (primary key `(user_id, id)`, since the table sync refuses a row id another account holds; `user_id` → `"user"` `ON DELETE CASCADE`,
  the fields of 3.1 with CHECKs, `client_updated_at`, `updated_at`, `deleted_at`) and `activity_days` (primary key
  `(user_id, day)`, the fields of 3.2), each with a pull index on `(user_id, updated_at, <tiebreak>)`; account caps
  (20,000 outside workouts, 5,000 days) kept in a new counter table `health_rows` with the existing trigger pattern
  (`account_rows.tbl` is CHECKed to its ten tables; changing that means rebuilding it and its 26 triggers); the new profile column `mcp_read_activity`
  (default 1).
- **Sync**: both tables join the generic table sync (`ENTITIES`), last write wins; they join `OWNED` for account
  deletion and the per-entity sync tests.
- **MCP**: `get_activity` (read, behind `mcp_read_activity`): `days` 1–84 (default 28) → outside workouts after
  rules 6–7 (newest first, at most 60; each with kind, start, duration, distance, kcal, `total_kcal`, avg and max
  HR, `avg_power_w`, `avg_cadence_rpm`, source, and `during_workout_id` when attached; an optional field only when
  the workout has it) and per-day and per-week totals. `get_training_insights`' streak counts outside
  workouts per decision 5. `SERVER_INSTRUCTIONS` and the app's coach prompt mention `get_activity` (check it before
  planning hard leg or conditioning days). The tool list grows from 16 to 17.

## 6. Rollout

1. Server: migration and deploy, **each with the owner's approval** and a D1 bookmark before the migration.
2. App: TestFlight build 4. Older builds ignore the new tables and the new profile column.
3. Release notes: the website privacy policy and the App Store privacy answers mention Health activity stored in the
   cloud and readable by connected agents behind the switch.

## 7. Testing

- GymCore: kind mapping, rules 6–7 and the streak count, against shared fixtures (also run by the server tests).
- GymHealth: `FakeHealthStore` gains outside workouts and day totals; import tests for the own-workout filter,
  deletions, the 7-day refresh, the switches, and state decoding from an old saved state.
- GymSync: DTO round trips, push/pull through `FakeTransport`.
- Server (vitest): the two entities in the generic sync tests, CHECK limits, account deletion, caps, `get_activity`,
  the switch, the streak, and the tool count.
- UI (`-fakeHealth`): a walk in Log and its detail, the ride's power, cadence and total calories, the attached
  measured block, steps on Today and the 7-day sheet, the two switches (also with Health off), the one-time card, and
  an accessibility audit of the activity screens.
