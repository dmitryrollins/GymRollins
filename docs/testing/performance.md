# Performance baselines

Run with `scripts/test-perf.sh` (`data` = GymData repository timings, `ui` = launch/scroll metrics; default both).
These are timing tests, so they are **not** part of `scripts/test-all.sh` / `scripts/ios-test.sh`
(`PerformanceUITests` is skipped there; the GymData suite only runs with `GYM_PERF=1`).

Measured 2026-09-28 on the development Mac (Apple silicon), Xcode 26 / iOS 26.2 simulator, iPhone 17 Pro.

## Repository queries (GymData, 150 workouts)

`WorkoutRepositoryPerformanceTests`: on-disk SwiftData store seeded with `OwnerSeed.applyLargeHistory(count: 150)`
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
