# Plan 08: End-to-end suite, accessibility, performance, final review

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close v1. Build one consolidated E2E suite that covers every flow on the mockup flow map (1.1–6.4), do
accessibility and Dynamic Type passes, measure logging-screen performance, run a full security review, a full Codex
review and a Claude review of the whole codebase, and produce a release-readiness report (what works locally, what
needs the cloud project, and what's deferred).

**Depends on:** Plans 01–07 merged.

**Conventions:** Branch `plan-08-e2e-polish`. Commit per task with the trailer lines. Never `git add -A`.

---

### Task 1: Flow-map coverage matrix

- [ ] Create `docs/testing/flow-coverage.md`: one row per flow-map step (1.1 Welcome … 6.4 Empty states), each
  with the test(s) that cover it (file::test), the type (unit/UI/HTTP/DB), and the status. Fill it by grepping the
  existing tests.
- [ ] For every uncovered or partially covered step, add a UI test (group them in
  `GymRollinsUITests/FlowCoverageUITests.swift`). Must-haves if missing: 3.3 rest settings changes the next rest
  duration; 3.5 how-to opens from logging; 3.7 exercise note persists after relaunch; 4.2 share sheet on workout
  detail; 5.2 custom exercise usable in a routine and workout; 6.2 sync conflict resolution (hermetic: DEBUG flag
  `-seedConflict` injects a conflict state into `SyncEngine` with a FakeTransport).
- [ ] **Commit:** `test(e2e): flow-map coverage matrix and gap tests`

### Task 2: Accessibility and Dynamic Type

- [ ] Add `GymRollinsUITests/AccessibilityAuditUITests.swift` that runs `XCUIApplication().performAccessibilityAudit()`
  (Xcode 15+ API) on Today, Logging, Workout overview, Summary, Log, Body, Library, Settings and Proposal review.
  Fix issues (contrast, missing labels, hit regions < 44 pt, clipped text), or record justified exclusions in the
  audit handler with a comment.
- [ ] Dynamic Type: launch with `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXL` and
  screenshot the logging screen and Today. The reps/weight boxes and Log Set must stay usable (layout switches to
  vertical stacking at accessibility sizes). Save the screenshots to `docs/screenshots/plan-08/a11y/`.
- [ ] VoiceOver labels: set rows read "Set 1, 8 reps, 140 pounds, done". The rest timer announces the remaining time
  on change (`accessibilityValue`). The hexagon badges are hidden from accessibility.
- [ ] **Commit:** `fix(a11y): audit fixes, dynamic type layouts, VoiceOver labels`

### Task 3: Performance

- [ ] `GymRollinsUITests/PerformanceUITests.swift`: `measure(metrics: [XCTApplicationLaunchMetric()])` for cold
  launch with the seed, and `XCTOSSignpostMetric.scrollDecelerationMetric` on Library and Log with 150 imported
  workouts (`-seedLargeHistory`, a new DEBUG flag generating 150 synthetic workouts). Targets: launch < 1.5 s on
  iPhone 17 Pro sim; no hitches > 100 ms in scroll (record the baselines).
- [ ] Check `WorkoutRepository.recent`/`history`/`bests` with 150 workouts in a GymData performance test (< 50 ms
  each on the Mac). Add indexes or caching (for example, a cached `ExerciseBests` per exercise updated on save) only
  if the targets are missed.
- [ ] **Commit:** `perf: launch/scroll baselines and repository performance tests`

### Task 4: Full reviews

- [ ] **Security review** (security-reviewer agent) of the whole repo: secrets, RLS, MCP, consent page, account
  deletion, logging hygiene, input validation, dependency pins.
- [ ] **Claude code review** (code-reviewer agent) of the whole codebase against the spec: architecture
  boundaries, immutability, file sizes (< 800 lines), function sizes, error handling, and dead code (placeholders
  left from earlier plans, such as `ComingSoonView` if unused).
- [ ] **Codex review**: `codex review --base <first commit>` over the whole history (or per-directory `codex exec`
  read-only reviews if the diff is too large). Save the outputs to `docs/reviews/`.
- [ ] Fix every CRITICAL/HIGH/P0–P2 finding test-first. Log MEDIUM/LOW items in `docs/reviews/backlog.md`.
- [ ] **Commit(s):** `fix: final review findings`

### Task 5: Release-readiness report and device install

- [ ] `docs/release-readiness.md`:
  - **What works locally** (with the tests that prove it).
  - **Needs the cloud project**: the Claude connector end to end, Sign in with Apple, TestFlight builds. Reference
    `docs/cloud-checklist.md`.
  - **Deferred** (from the spec's "Not in v1", plus the review backlog).
  - **Exercise media licensing decision** needed before the App Store.
- [ ] Device build: `xcodebuild -project ios/GymRollins.xcodeproj -scheme GymRollins -destination 'generic/platform=iOS' -configuration Debug build`
  with the team from `Local.xcconfig`. Report whether signing works (the owner may need to plug in the iPhone and
  trust the developer certificate; instructions go in the report).
- [ ] Update README (architecture overview, how to run everything, the test matrix).
- [ ] Merge to `main`, then tag `v0.1.0`.
