# Plan 14: Strength levels (Beginner → Elite) for squat, bench press and deadlift

Date: 2026-09-29 · Branch `feat-strength-levels` (worktree `wt-strength`) · Wave 2.

## Goal

For the three barbell lifts, show where the owner's estimated 1RM sits — a level (Beginner, Novice,
Intermediate, Advanced, Elite), a percentile among raw powerlifting competitors of the same sex, age group and
bodyweight, and what the next level takes ("+15 lb to Intermediate") — in the Body tab, on the lift's history
screen and for Claude (MCP).

## Data (build time)

- Source: OpenPowerlifting bulk CSV, `openpowerlifting-2026-09-26-f231b4f6.csv` (from
  `https://openpowerlifting.gitlab.io/opl-csv/files/openpowerlifting-latest.zip`, downloaded 2026-09-29, zip
  sha256 `32a90763…0f98`). Data is public domain (bundled `LICENSE.txt`, quoted in
  `docs/licenses/openpowerlifting.md`). Only the data is used; none of the AGPLv3 code.
- `scripts/build-strength-standards.mjs` (Node, streaming, no dependencies; tests on synthetic rows in
  `scripts/build-strength-standards.test.mjs`) writes `ios/GymRollins/Resources/strength-standards.json` and a
  byte-identical `supabase/functions/_shared/strength-standards.json` (~106 KB each). The raw CSV lives outside
  the repo (`../opl-cache/`) and is deleted after the build.

### Filters (documented in the JSON's `method`)

| Filter | Choice | Why |
|---|---|---|
| Equipment | `Raw` only | Knee sleeves at most — closest to gym training. `Wraps` adds ~5–10 % to the squat. |
| Tested | all | Tested-only changes the 81 kg / 23–39 male p5/p20/p50/p80 by ≤ 0.8 kg (checked); all keeps bigger bins. |
| Place | numeric only | Drops DQ, doping DQ, no-show and guest rows. |
| Lift | `Best3<Lift>Kg > 0` and the event contains the lift | A bench-only meet counts for the bench only. |
| Sex | `M`, `F` | `Mx` is too small to bin. |
| Bodyweight | 30–250 kg, present | |
| Age | `Age`, else the `AgeClass`/`BirthYearClass` midpoint; ≥ 14 | Many federations give classes only. |
| Date | meets on/after 2012-01-01 | The modern raw era. |
| Dedupe | one result per lifter (Sex + Name) per lift: the heaviest, ties → latest | Frequent competitors would otherwise dominate. |

4.04 M rows read → 1.20 M lifter×lift results.

### Bins, percentiles, smoothing, fallback

- Sex × age group (`u23` 14–22, `open` 23–39, `m40` 40–49, `m50` 50–59, `m60` 60+) × 5 kg bodyweight bins
  (men 50…160+, women 40…130+; the first/last bins are open-ended).
- Per bin: percentiles 1, 2, 5, 10, 15, 20, 25, 30, 40, 50, 60, 70, 75, 80, 85, 90, 95, 98, 99 of
  lift ÷ bodyweight, times the bin's median bodyweight (`bw`).
- Fewer than 60 lifters: pool bodyweight neighbours (±1…3 bins, same age group); still short → the open group's
  pool at that bodyweight. Each bin records `n` (own lifters), `pooled` and `source` (`own`, `bw±k`, `open`).
- Smoothing across bodyweight per percentile: weighted isotonic regression (lifts never fall as bodyweight rises),
  then a 3-bin weighted moving average; percentiles forced non-decreasing within each bin.

## Level mapping

Raw competitors are a strong, self-selected group: at 81 kg / 23–39 / male their **p1** bench is 77.6 kg, the p5
is 94.7 kg (1.17 × bodyweight). Mapping "Beginner < p5" would call almost every gym lifter a beginner. So the
thresholds are anchored on the competitor curve (at the lifter's sex, age group and bodyweight) but the two lower
ones sit **below** the competitor distribution, as fractions of its median:

| Level | From | 81 kg, male, ~35 (open) — squat / bench / deadlift | × bodyweight (bench) |
|---|---|---|---|
| Beginner | 0 | 0 | |
| Novice | 0.45 × p50 | 85.9 / 59.0 / 100.5 kg | 0.73 |
| Intermediate | 0.65 × p50 | 124.1 / 85.2 / 145.1 kg | 1.05 |
| Advanced | p20 | 163.5 / 111.8 / 194.6 kg | 1.38 |
| Elite | p80 | 220.3 / 151.2 / 252.0 kg | 1.87 |

(At exactly 81 kg: the app interpolates between the 78.4 kg and 81.8 kg bins' curves. The competitors' p1 there is
109.5 / 76.3 / 136.4 kg.) These line up with common gym strength
standards (bench ≈ 0.75 / 1.0 / 1.5 / 1.9 × BW for novice/intermediate/advanced/elite; a first-year lifter reads
Beginner or Novice, a lifter who could enter a meet reads Intermediate or Advanced, the top fifth of meet lifters
Elite). The thresholds live in the JSON (`levels: [{id, name, percentile, fraction}]`) so Swift and TS share
them. Percentile is reported against raw competitors ("stronger than 23 % of raw competitors"); below p1 it's
"under 1 %", above p99 "over 99 %".

Worked example (owner): bench e1RM 78.6 kg (Epley, 130 lb × 10), 81 kg, male, 35 → Novice, stronger than ~1 % of
raw competitors, next: Intermediate at 85.2 kg → "+15 lb to Intermediate" (the 14.4 lb gap rounded up to 2.5 lb /
0.5 kg).

## Inputs (app)

- **e1RM**: the best `WorkoutMetrics.bestE1RM` (Epley, done non-warm-up sets, 1–12 reps) over finished workouts in
  the last 365 days. Exercises (`StrengthLift.mapping`): squat `0043` barbell full squat (+ `1461`/`1462` POV
  duplicates, `1435` low bar, `1436` high bar); bench `0025` barbell bench press; deadlift `0032` barbell deadlift
  and `0117` sumo deadlift (competition-legal). All at factor 1.0. Front squat, close-grip/incline bench, RDL etc.
  are **not** mapped: their ratio to the competition lift varies too much between people to discount reliably.
- **Bodyweight**: the latest Body weigh-in.
- **Sex and birth year**: new optional profile fields (`sex` = male/female, `birthYear`), asked for in the
  Strength level section ("Used only to compare your lifts with lifters like you."), editable from the method sheet.
  Age = current year − birth year (OpenPowerlifting ages are also often year-based). Under 14 → not shown.
  Stored and synced like the rest of the profile (`profiles.sex`, `profiles.birth_year`, CHECKs, drift-guarded
  `DomainLimits.birthYear` 1900…2100). `ProfileRepository.save` never writes them (the many screens that rebuild a
  `Profile` can't wipe them); `setStrengthProfile(sex:birthYear:)` does. `get_profile` does not return them.
- **Knee note**: if `LimitedMuscles.from(limits:)` flags the legs, squat and deadlift rows keep their numbers but
  show "Paused — injury note" and no "+x to next level" nudge.

## GymCore (pure)

- `StrengthStandards` — `Decodable` table; `curve(sex:lift:age:bodyweightKg:)` interpolates linearly between the
  two bins bracketing the bodyweight (clamped at the ends); `ageGroup(age:)`.
- `StrengthLevelCalculator.assess(...)` → `StrengthAssessment` (level, percentile, thresholds, next level target
  and gap). Exactly on a threshold counts as the higher level.
- `StrengthLevelInputs.best(workouts:lift:since:)` → best e1RM, date, exercise id.
- `StrengthGap.text(kg:unit:)` — "+17.5 lb", rounding the gap up to 2.5 lb / 0.5 kg.
- Shared fixture `fixtures/strength-levels.json` (cases on the real table) run by Swift and TS.

## App

- Body tab: "Strength level" card after weekly sets: three rows (lift, level badge, e1RM, percentile, progress bar
  to the next level, "+x to Level" or "Paused — injury note"); empty states: no sex/birth year (button "Add sex &
  birth year"), no weigh-in, no lift logged in 12 months. Tap → method sheet (how it works, data source and
  version, your inputs, per-level thresholds for the lift in your unit, edit sex/birth year).
- Exercise history (mapped exercises): the same row above History/Trends.
- Credits: `CREDITS.md` + `docs/licenses/openpowerlifting.md`.
- Debug seed `-seedStrength` (adds sex/birth year to the owner seed; `-seedInsights` + `-seedBodyweight` history).

## MCP

`get_strength_levels` (read, audited like every tool): needs the owner's workouts, body and plan read permissions
(profile holds sex/birth year). Same maths via `_shared/strength-levels.ts` + the shared fixture; e1RM from
`workouts` (365 days). Returns per lift: level, percentile, e1RM, bodyweight used, next level + target, paused
flag, and `missing` inputs.

## Tasks (TDD, commit per task)

1. Builder + tests + generated JSON + licence doc.
2. GymCore: standards, calculator, inputs, gap text, `DomainLimits.birthYear` + fixture tests.
3. DB migration (`sex`, `birth_year`) + pgTAP; TS `DomainLimits`.
4. GymData/GymSync: profile fields, repository, snapshot, DTO; tests.
5. App: model, Body card, method sheet, profile sheet, history row, credits, seed; unit + UI tests; screenshots in
   `docs/screenshots/strength/`.
6. MCP: `_shared/strength-levels.ts`, tool, FakeDb, tests.
7. Full suites, swiftlint, `codex review --base main` until clean.
