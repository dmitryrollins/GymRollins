# Performance baselines

Run with `scripts/test-perf.sh` (`data` = GymData repository timings, `ui` = launch/scroll metrics; default both).
These are timing tests, so they are **not** part of `scripts/test-all.sh` / `scripts/ios-test.sh`
(`PerformanceUITests` is skipped there; the GymData suite only runs with `GYM_PERF=1`).

Measured 2026-09-28 on the development Mac (Apple silicon), Xcode 26 / iOS 26.2 simulator, iPhone 17 Pro.

## Repository queries (GymData, 150 workouts)

`WorkoutRepositoryPerformanceTests`: on-disk SwiftData store seeded with `SampleSeed.applyLargeHistory(count: 150)`
(4 exercises × 3 sets per workout, like an imported Fitbod session), release build, median of 10 runs after a
warm-up. Target: **< 50 ms each**.

| Query | Before | After | Target |
|---|---:|---:|---|
| `recent(limit: 50)` (Log's first page) | 100 ms | **5.6 ms** | met |
| `recent(limit: 200)` (all 150) | 314 ms | **16.1 ms** | met |
| `history(exerciseId: bench, limit: 1)` (logging hint) | 26 ms | **14.8 ms** | met |
| `history(exerciseId: bench, limit: 200)` | 96 ms | **15.6 ms** | met |
| `bests(exerciseId: bench)` (150 sessions, PR check) | 81 ms | **15.4 ms** | met |
| `bests(exerciseId: 0314)` (~64 sessions) | 34 ms | **7.0 ms** | met |

**Why it was slow:** materializing SwiftData rows costs ~25 µs each, and after a fetch every to-many relationship
(`workout.entries`, `entry.sets`) faults with its own SQL query, so reading 50 workouts touched ~850 rows via ~250
queries. Bulk-fetching sets by entry only got `recent(50)` to ~64 ms.

**Fix:** `WorkoutRecord.entriesData`, a JSON cache of the workout's `[WorkoutEntry]` written together with the
entry/set rows by `WorkoutRecord.setEntries(_:in:)` (the only writer: `WorkoutRepository.save/saveActive` and sync's
`applyRemote`/conflict resolution). Reads decode it instead of walking the relationships; rows written before the
cache existed fall back to the relationships until they are next saved. `history`/`sessions`/`bests` now filter and
sort workouts in SQL (`entries.contains { exerciseId }`, `startedAt` desc) and take entries from the cache.
Covered by `RepositoryTests.entriesCacheMatchesRowsAndFallsBack` and the existing sync tests.

## Launch and scroll (PerformanceUITests, iPhone 17 Pro simulator, Debug build)

| Metric | Result (avg of 5) | Target | Status |
|---|---:|---|---|
| Cold launch to first responsive frame (`XCTApplicationLaunchMetric`, `-uiTesting -seedHistory`) | 1.80 s (RSD 0.9%) | < 1.5 s | **missed** (see below) |
| Library scroll (2 flings up, 2 down) — deceleration / dragging | 2.42 s / 0.14 s | no hitches > 100 ms | hitches not reported on the simulator |
| Log scroll, 150 workouts (`-seedLargeHistory -largeHistoryCount 150`) — deceleration / dragging | 2.43 s / 0.14 s | no hitches > 100 ms | hitches not reported on the simulator |

- **Scroll:** the simulator only reports the `Scroll_Deceleration`/`Scroll_Dragging` durations of
  `XCTOSSignpostMetric.scrollDecelerationMetric`/`scrollDraggingMetric`; hitch count/time ratio need a device.
  The durations are flat across iterations (RSD < 6%) and the same for Library (1,300+ rows) and Log (150 cards),
  i.e. no content-dependent stalls. Re-run `scripts/test-perf.sh ui` on the device (Task 5) for hitch numbers.
- **Launch:** 1.80 s includes simulator process spawn, a Debug build, `-uiTesting`'s in-memory store seeding (owner
  plan + history) and decoding the bundled 1,324-exercise library, so it overstates a Release launch on a device.
  Not optimized in this pass; candidates if the device number also misses: decode `exercises.json` off the main
  thread / lazily after first frame, and defer non-UI seeding work.

## Today and Library taps (2026-11-16)

About half of the taps on Today and Library answered late on a physical iPhone with a large history. The main thread was busy with work that ran on every layout, reload or refresh. Measured with
`ResponsivenessTimingTests` (app, Debug, iPhone 17 Pro simulator, median of 20; 160 workouts of 6 × 3 sets with the
bench in 100, and 500 outside workouts) and `HistoryTimingTests` (GymData, release, Mac):

| Work | Before | After | Fix |
|---|---:|---:|---|
| 10 muscle badges' paths at 31 pt (every Library/Today layout) | 54 ms | **1.5 ms** | silhouette and group paths built once in source units, then only scaled (`BodyMapData`; load 23 ms once) |
| Recovery card's two figures | 10.4 ms | **0.1 ms** | same |
| `history(staple, limit: 5)` (GymData, release) | 13.9 ms | **1.1 ms** | read `limit` workouts at a time until enough (`WorkoutRepository`) |
| History for a 7-item plan (app) | 109 ms | **6.8 ms** | same, and Today keeps it until the workouts change (`TodayHistoryCache`) |
| Library body pass (3 searches + body parts) | 6.2 ms | **0.5 ms** | one search per pass; facets and search keys built with the library |
| `insights()` (Today calls it twice per refresh) | 86 ms | **0.1 ms** reused, 21 ms in a new minute, 83 ms once per data change | `InsightsMemo` on `AppEnvironment` |
| Today after a sync that brought rows | 394 ms | **103 ms** | all of the above |
| Today back in the foreground, nothing changed | ~190 ms | **33 ms** | all of the above |

What's left per data change is resolving the outside workouts (`ActivityRules.resolve`, 500 × 160: 47 ms Debug,
11 ms release on the Mac); rule 7's same-session check is quadratic. `ResponsivenessUITests` taps Today's and
Library's rows with 160 workouts (every tap must open its screen) and attaches a Library screenshot.

Run: `scripts/test-perf.sh data` (GymData), and for the app harness
`TEST_RUNNER_GYM_PERF=1 scripts/ios-test.sh -only-testing:GymRollinsTests/ResponsivenessTimingTests`, then
`xcresulttool export attachments --path <xcresult> --output-path <dir>` (each test attaches `timings.txt`).
