# Plan 12: Insights — recovery muscle map, weekly set targets, streaks

Date: 2026-09-29 · Branch `feat-insights` (worktree `wt-insights`) · Owner-approved scope (Wave 1, workstream B).
These three features were "Not in v1" in the spec (§1); this plan adds them.

## Goal

Fitbod-style training insights computed from the workouts already on the device (and, for Claude, from the synced
workouts on the server):

1. **Recovery muscle map** — per muscle group recovery % from recent sets; a front/back body map (SwiftUI
   paths) on a Today card and in the Body tab; tap a muscle for its %, last trained date and recent sets.
2. **Weekly set targets** — hard sets per muscle group this week vs an editable target range; progress bars in the
   Body tab, a compact line on the workout Summary, editing in Settings → Weekly targets; synced.
3. **Streaks** — consecutive weeks meeting the weekly workout goal; current/longest on a Today header chip and in the
   Log tab; a subtle celebration on Summary when the finished workout completes the week's goal.
4. **Claude** — one MCP read tool, `get_training_insights`, returning the same three numbers.

## Domain model (GymCore, pure, injected clock/calendar)

### Muscle groups (16)
`MuscleGroup`: chest, shoulders, traps, upperBack, lats, lowerBack, biceps, triceps, forearms, abs, glutes, quads,
hamstrings, calves, adductors, abductors. Legs = glutes, quads, hamstrings, calves, adductors, abductors.

`MuscleTaxonomy` maps the library's strings (`tg` = primary target, `sm` = secondary muscles) onto groups, e.g.
`pectorals → chest`, `delts/shoulders/deltoids/rear deltoids/rotator cuff → shoulders`, `spine/lower back →
lowerBack`, `upper back/rhomboids/back → upperBack`, `core/obliques/hip flexors/abdominals → abs`,
`brachialis → biceps`, `soleus/ankles/feet/shins → calves`, `inner thighs/groin → adductors`,
`sternocleidomastoid/levator scapulae → traps`, `cardiovascular system → none`. A custom exercise whose target isn't in the table falls back
to its body part (`upper legs → quads, hamstrings, glutes`, …), each at the primary weight divided by the number of
groups. Primary weight **1.0**, secondary **0.5** (a group listed as both counts as primary).

### Which sets count ("hard sets")
Done, not warm-up, from a finished workout, exercise not cardio (`mode == .cardio` / body part `cardio`), and with
some work (reps > 0, or seconds/minutes > 0 for timed sets). Bodyweight sets (0 kg) count like any other set.
Effort when logged: RIR (or 10 − RPE) 0–1 → 1.0, 2 → 0.9, 3 → 0.75, 4 → 0.6, ≥ 5 → 0.5; unlogged → 1.0.

### Recovery (`RecoveryModel`)
Per workout (timestamp = `endedAt ?? startedAt`; future workouts ignored), per group:
`load = Σ set effort × role weight`.
- Initial fatigue `f0 = min(1, load / 6)` (6 effective sets ≈ fully fatigued).
- Recovery time `h = clamp(24 + 6 × load, 24, 96)` hours → 3 sets ≈ 42 h, 4 sets = 48 h ("normal"), 8 sets = 72 h,
  12+ sets = 96 h.
- Remaining fatigue decays linearly: `f(t) = f0 × max(0, 1 − Δt / h)`.
- Sessions stack: `fatigue = min(1, Σ f_i)`; **recovery % = round(100 × (1 − fatigue))**. No history → 100 %.
- Status: fresh ≥ 90 %, recovering 50–89 %, fatigued < 50 %.
- "Fresh" hint on Today: fresh groups trained in the last 28 days (the owner's rotation), excluding limited groups,
  most-recovered first then longest since trained, top 3.

### Limited (injury) state
There is no structured injury model: the profile's free-text `limits` ("Knee: no leg loading until ~26 Oct 2026")
is the only data. The map reuses it display-only: if the text mentions a knee or legs, the leg groups are drawn in
the "limited" state (striped, "Limited — see your limits note") and left out of the Fresh hint. Nothing else
(recovery maths, routine selection, suggestions) changes. Clearing the text clears the state.

### Weekly sets (`WeeklySets`)
Hard sets per group in the training week containing `now` (primary 1, secondary 0.5 — e.g. bench = 1 chest,
0.5 triceps, 0.5 shoulders). **Week = Monday–Sunday in the device time zone** (same as the Log tab's week strip and
the MCP summary's Mon–Sun weeks). Default targets: major groups (chest, shoulders, upper back, lats, quads,
hamstrings, glutes) **10–20**; small groups **6–12**. Status: below / in range / above.

### Streak (`StreakCalculator`)
Weekly goal = `profile.trainingDays` (exists; 1–7). A week meets the goal when it has ≥ goal **distinct training
days** with a finished workout (a double session on one day counts once). Current streak = consecutive goal-met
weeks ending with the current week if it's already met, else with last week (the current week is "in progress" and
never breaks a streak). A week below goal (including a rest week with no workouts) breaks it. Longest = the
longest run in all history. Summary celebrates when the finished workout makes this week's count reach the goal
exactly (celebration is a static card; the symbol bounce is skipped under Reduce Motion).

## Persistence + sync (weekly targets)

New table `public.muscle_targets` — primary key `(user_id, muscle)`, `min_sets`, `max_sets`, `client_updated_at`,
`updated_at` (like `week_schedule`: no tombstones; "reset" writes the defaults). CHECKs: muscle in the 16 ids,
`0 ≤ min ≤ max ≤ 50` (`DomainLimits.weeklySetTarget`, drift-guarded). Same triggers (`lww_guard`,
`set_updated_at`), RLS: owner reads (MCP clients only with `mcp_flag('plan')`), owner writes (never MCP clients).
pgTAP: RLS isolation, MCP read-only/plan flag, CHECKs, LWW.

App: `MuscleTargetRecord` (SwiftData), `MuscleTargetRepository`, `SyncEntity.muscleTargets`, `SyncStore`
dirty/applyRemote, `MuscleTargetDTO`, `SupabaseTransport` push/pull (`onConflict: user_id,muscle`), `SyncEngine`
push/pull after the week schedule. A separate table (not a profile column) keeps profile edits and target edits
from overwriting each other under per-row last-write-wins.

## MCP (`get_training_insights`)

Computed in the Edge Function from rows the caller's RLS already exposes (workouts ← `mcp_read_workouts`, targets ←
`mcp_read_plan`, profile for the weekly goal and limits): a TypeScript port of the GymCore functions
(`supabase/functions/_shared/insights.ts`). Swift and TS are kept identical by a shared fixture
(`fixtures/insights.json`) that both test suites run. Weeks are Mon–Sun UTC server-side (like
`get_training_summary`). Simpler and as secure as a SQL view: no new SQL surface, RLS unchanged, audited like every
tool.

## Body figure (owner decision 2026-09-29)

The map draws the region outlines of **vulovix/body-muscles** (Apache-2.0, pinned `15c8085e`; attribution in
`docs/licenses/body-muscles.md`, Settings → Credits and the bundled `body-muscles-LICENSE.txt`) instead of
hand-drawn shapes. `scripts/build-body-map.mjs` extracts the 89 front/back region paths and view boxes into
`Resources/body-map.json` (no npm dependency in the app); `SVGPath.swift` parses the path data into SwiftUI paths.
`BodyMapRegions` maps each upstream region onto a display group (left/right share one; `traps-mid/lower` →
upper back, `gluteus-medius` → abductors, `tibialis-anterior` → calves, `serratus-anterior` → chest, `neck`/`nape`
→ traps) or draws it as the neutral outline (head, face, hands, feet, elbows, knees, hip flexors). Tests check
every region is mapped or neutral and every group has at least one region.

## UI

- `RecoveryCard` (Today, inserted after the limits/proposal chips; TodayView gets two one-line insertions: the
  card and the streak chip in the header). Summary line + mini body + "Fresh: back, biceps". Tap → `RecoveryMapView`.
- `RecoveryMapView`: front/back toggle, `MuscleRegionShape` regions (body-muscles paths, see above), legend, list of groups; tap a region
  or row → `MuscleDetailSheet` (recovery %, last trained, recent sets).
- Body tab: "Muscle recovery" section (compact map + link) and "Weekly sets" section (bars vs target ranges).
- Settings → Training → "Weekly targets" → per-muscle min/max steppers + "Reset to defaults".
- Summary: "Chest 12/10–20 this week" lines for the groups this workout trained; goal-met celebration card.
- Log tab: streak card (current, longest, this week x/goal).
- Accessibility: each region is a button labelled "Chest, 80% recovered"; colours come with text/percentages.

## Tasks (TDD, commit per task)

1. GymCore: `MuscleGroup`, `MuscleTaxonomy`, `HardSets`, `RecoveryModel`, `WeeklySets`, `StreakCalculator`,
   `LimitedMuscles` + tests (edge cases: no history, stacking, bodyweight, cardio, warm-ups, RIR/RPE, future
   workouts, week boundaries across time zones, DST, rest weeks). `fixtures/insights.json` cases.
2. DB: migration + pgTAP; `DomainLimits.weeklySetTarget` + TS port.
3. GymData: record, repository, queries (`finishedWorkouts(since:)`, `finishedStartDates()`), SyncStore; tests.
4. GymSync: DTO, transport, engine; FakeTransport tests.
5. App: insights model, views, Settings screen, Today/Body/Log/Summary placement, debug seed `-seedInsights`.
6. MCP: `_shared/insights.ts` + fixture test, `get_training_insights` tool + FakeDb tests, http tool list.
7. UI tests + screenshots (`docs/screenshots/insights/`); full suites; swiftlint; `codex review --base main` loop.
