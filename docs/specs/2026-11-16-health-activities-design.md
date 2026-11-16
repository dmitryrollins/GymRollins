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

## 3. Data

### 3.1 Outside workout (`HealthActivity`)

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | The HealthKit workout's UUID: two devices of one account importing the same workout write the same row. Unique per account, not globally (one iPhone's Health can be read into two accounts). |
| `kind` | text | A stable slug mapped from `HKWorkoutActivityType` (`walking`, `running`, `cycling`, `hiit`, `yoga`, `swimming`, `traditional_strength`, `functional_strength`, `elliptical`, `rowing`, `hiking`, `dance`, `core`, `pilates`, `cooldown`, … `other`). Unknown types become `other`. |
| `startedAt`, `endedAt` | timestamps | |
| `durationS` | real | HealthKit's duration (pauses excluded). |
| `kcal` | real? | The workout's active energy statistic. |
| `distanceM` | real? | Walking/running, cycling or swimming distance, whichever the workout has. |
| `avgHr`, `maxHr` | int? | From the workout's heart-rate statistics. |
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
duration 0–24 h, kcal 0–20,000, distance 0–1,000 km, heart rate 20–250, steps 0–200,000, exercise 0–1,440 min,
stand 0–24 h, kind and source name 1–100 characters. A sample outside them is skipped on import, not clamped.

## 4. Phone

- **Reading from Health.** `HealthStore` gains read methods: outside workouts changed since an anchor (added + deleted)
  and day totals for a date range. `HealthKitStore` asks to read step count, active energy, exercise time,
  heart rate, the distance types and Activity summaries (besides what it reads now). Read types are **not** added to
  `HealthDataType` (that enum is the write list; its summary would never say "Connected" again).
- **State.** New `HealthSyncState` fields (activity anchor, import start, the two reading switches, whether the new
  permissions were asked) use the optional-storage pattern, so an old saved state still decodes. (A decode failure
  resets the whole state, which would turn Health off and drop the export ledgers.)
- **Permissions for people who already use Health.** The system asks only once per type, and today it only asks in
  `enable()`. With Health on and the new types never asked, Today shows a one-time card, "Bring in your Apple Watch
  activity", with **Allow** (asks Health, then imports) and **Not now**. Settings › Apple Health has the same ask.
- **Settings › Apple Health** gets a "Reading from Health" section: **Workouts from other apps** and **Steps &
  activity**, both on by default while Health is on. Turning one off stops that import and hides that data in the
  app; nothing already in the cloud is deleted.
- **Storage.** Two new SwiftData models and repositories in GymData; two new sync kinds (pushed after workouts),
  wired everywhere a kind is registered (store tracking, account reset, ownership, server move, debug transports,
  sync status names).
- **Log.** Outside workouts that aren't attached appear in the history between GymRollins workouts as compact
  read-only cards: kind icon, name ("Walk"; titles come from the kind, there's no indoor/outdoor field), date · duration, distance, kcal, source. A tap opens a detail
  screen with the same facts plus average/max heart rate and "Change or delete it in the Health app." The week strip
  counts their minutes in a lighter shade. The kcal line follows decision 10.
- **GymRollins workout detail.** With an attached outside workout: "Apple Watch measured 412 kcal · avg 128 bpm ·
  max 162 bpm" under the calorie card.
- **Today.** An Activity row with today's steps, move kcal and exercise minutes; a tap shows the last 7 days. Hidden
  when Steps & activity is off or there's no data for the last 7 days.
- **Streak and weekly goal** count outside workouts per decision 5.
- **Purpose string.** `NSHealthShareUsageDescription` says the app reads workouts from other apps, steps, activity
  and heart rate, besides weight and body fat.

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
  rules 6–7 (newest first, at most 60; each with kind, start, duration, distance, kcal, avg HR, source, and
  `during_workout_id` when attached) and per-day and per-week totals. `get_training_insights`' streak counts outside
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
- UI (`-fakeHealth`): a walk in Log and its detail, the attached measured line, steps on Today and the 7-day sheet,
  the two switches, the one-time card.
