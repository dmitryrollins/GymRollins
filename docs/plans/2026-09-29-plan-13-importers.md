# Plan 13 — Importers for Strong, Hevy and FitNotes

Branch `feat-importers`. Extends the Fitbod-only CSV import (plan 07) to three more apps, behind one
`WorkoutImporter` protocol, reusing the existing pipeline: parse → rows → exercise matching (per-app alias table,
unmatched → the resolve-unmatched UI) → `ImportPlan` → `ImportService`.

## Research: export formats (sources)

| App | Header(s) | Notes |
|---|---|---|
| Strong (current, comma) | `Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,Notes,Workout Notes,RPE` (some builds omit `Notes,Workout Notes`) | No unit column: weight is in the app's unit setting → the user picks kg/lb. Distance in meters. `Duration` is workout-level `1h 5m` / `41m`. `Seconds` is per-set duration. `Set Order`: `1..n`, `W` warm-up, `D` drop, `F` failure; `Rest Timer` / `Note` rows are not sets. Dates `yyyy-MM-dd HH:mm:ss`, local time, no offset. |
| Strong (older Android, `;`) | `Date;Workout Name;Exercise Name;Set Order;Weight;Weight Unit;Reps;RPE;Distance;Distance Unit;Seconds;Notes;Workout Notes;Workout Duration` | Per-row `Weight Unit` / `Distance Unit`. Delimiter sniffed from the header line. |
| Hevy | `title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,set_type,weight_kg,reps,distance_km,duration_seconds,rpe` (imperial: `weight_lbs`, `distance_miles`) | Unit is in the column name. Dates `d MMM yyyy, HH:mm` (older/other locales: `MMM d, yyyy, h:mm a`), local time. `set_type`: `normal`, `warmup`, `drop_set` (also `dropset`), `failure`; unknown → normal. |
| FitNotes | `Date,Exercise,Category,Weight (kg),Weight (lbs),Reps,Distance,Distance Unit,Time,Notes,Kind` (older Android: a single `Weight (kgs)` or `Weight (lbs)` column; some exports `Comment`) | Date only (`yyyy-MM-dd`), no time of day. `Time` is per-set `MM:ss` or `HH:MM:ss`. `Distance Unit`: `m km cm in ft yd mi`. No warm-up/superset/RPE. `Kind` ignored. |

Sources:
- Strong help — export: https://help.strongapp.io/article/235-export-workout-data
- Strong parsers/fixtures: https://github.com/IgnisDa/ryot/blob/main/crates/services/importer/strong-app/src/lib.rs (delimiter sniffing, `W/D/F`, `Rest Timer`/`Note` rows), https://github.com/edvanbeinum/StrongCsvParser (fixture, BOM), https://github.com/DaKheera47/strong-statistics, https://github.com/AlexandrosKyriakakis/StrongAppAnalytics/blob/main/Code/strong.py
- Strong Android `;` header: https://github.com/thomasetienne/iron-fitness/blob/main/data/SOURCES.txt, https://github.com/rhnfzl/Fitbod2HevyConverter
- Hevy parsers/fixtures: https://github.com/gossamr/swift-workout-importer (`Tests/WorkoutImporterTests/Fixtures/hevy-*.csv`), https://github.com/IgnisDa/ryot/blob/main/crates/services/importer/hevy/src/lib.rs, exercise names https://github.com/drkostas/hevy2garmin/blob/main/typescript/src/muscle-groups.ts
- Hevy help (export path): https://help.hevyapp.com/hc/en-us/articles/35687878672663
- FitNotes docs (CSV columns, units, time format): https://www.getfitnotes.com/docs/migrate-from-other-apps.html; fixtures: https://github.com/gossamr/swift-workout-importer; default names: https://github.com/mylesverdon/FitNotes-iOS/blob/main/FitNotes/Model/Exercise.swift, https://github.com/tihawk/fitnotes2fit

Unverified / conflicting (handled defensively): Strong `W/D/F` codes (seen in importers, not in the decompiled
source); Hevy `drop_set` vs `dropset`; Hevy's two date formats; decimal-comma values (not seen in any source, but
`;` exports accept `60,5`).

## Design

GymCore (`Import/`):
- `ImportTypes.swift`: `ImportSource`, `ImportOptions` (weight unit when the file has none, time zone for
  offset-less timestamps), `ImportedWorkout` (+ `name`, `endedAt`, `note`), `ImportedEntry` (+ `supersetGroup`),
  `ImportedSet` (+ `rpe`), `WorkoutImportResult` (+ `source`, `ignoredRowCount`), `WorkoutImportError`
  (+ `sourceMismatch`). `FitbodImportResult` / `FitbodImportError` stay as typealiases.
- `WorkoutImporter` protocol (`recognizes(header:)`, `needsWeightUnit(header:)`, `parse(_:options:)`) and
  `WorkoutImporters` (registry, `detect`, `parse(text, source: nil = auto-detect)`).
- `ImportSupport.swift`: header-by-name table, delimiter sniffing (`CSVParser.detectDelimiter`), decimal-comma
  numbers, shared bounds, grouping into workouts, deterministic ids.
- `StrongImporter`, `HevyImporter`, `FitNotesImporter`; `FitbodImporter` conforms (ids unchanged).
- Ids: Fitbod unchanged (`[Date] + names`); Strong/Hevy `[app, start, title]`; FitNotes `[app, date]`.

App:
- `ImportAliases.load(source)` → `strong-aliases.json`, `hevy-aliases.json`, `fitnotes-aliases.json`.
- `ImportService`: per-source name/note, export's `endedAt`, RPE, superset group (one entry per exercise and
  superset); **dedupe**: a workout with a new id starting within 60 s of an existing workout is skipped and counted
  (same id → overwrite = idempotent). FitNotes' made-up noon starts are never matched by time, in either direction.
  Strong/Hevy/FitNotes log a dumbbell's weight per hand, so library two-dumbbell movements import with
  multiplier 2 (single-dumbbell ones — goblet, one-arm, concentration, two-hand extension — stay 1); Fitbod keeps
  its own `multiplier` column. Names that only occur in skipped duplicates create no custom exercise.
- `ImportCSVView`: source picker (Auto-detect / Fitbod / Strong / Hevy / FitNotes) + a help line per app on how
  to export; kg/lb picker when the file doesn't carry its unit (Strong's current export), defaulting to the
  profile unit; a mismatch error names the detected app. `-importFixture <source>` for UI tests.
- Formula-injection neutralization (export) and the 25 MB cap (`ImportFile`) apply to every source unchanged.

## Tasks (TDD)
1. CSVParser delimiter param + sniffing (tests first).
2. Shared types/protocol; Fitbod conformance; existing Fitbod tests stay green.
3. Synthetic fixtures (`ios/GymRollinsTests/Fixtures/{strong,strong-semicolon,hevy,hevy-lbs,fitnotes}-sample.csv`)
   + per-format GymCore tests (header detection, units, set types, durations/distances, malformed rows).
4. Alias tables for the ~40–60 most common names per app + `AliasTableTests` for each; review doc
   `docs/import/other-apps-alias-review.md` (generated by `scripts/other-apps-alias-report.mjs`).
5. ImportService integration tests (Strong/Hevy/FitNotes import, dedupe, idempotent re-import).
6. UI: picker + help + unit choice; UI tests import Strong and Hevy fixtures through Settings → Import.
7. `scripts/ios-test.sh`, package tests, swiftlint; `codex review --base main` until clean.
