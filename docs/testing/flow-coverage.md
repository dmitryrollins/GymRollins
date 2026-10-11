# Flow-map coverage matrix

Every step of the flow map (`docs/design/Flow.dc.html`, 1.1 – 6.4) mapped to the tests that exercise it.
Built by reading the suites on 2026-09-27 (Plan 08, Task 1). Gap tests added by this task live in
`ios/GymRollinsUITests/FlowCoverageUITests.swift` (marked **new**).

**Type:** UI = XCUITest (`ios/GymRollinsUITests`, hermetic unless noted) · Unit = Swift Testing
(`ios/GymRollinsTests`, `ios/Packages/*/Tests`) · HTTP = deno (`supabase/functions`) / node (`web/consent`) ·
DB = pgTAP (`supabase/tests/database`) · E2E = opt-in against the local Supabase stack
(`scripts/ios-test-sync.sh`, `SYNC_E2E=1` / `MCP_E2E=1`).

**Status:** covered = the step's user-visible behaviour is driven end to end and asserted · partial = some of the
step is driven, the rest only at unit level or not at all (reason given) · uncovered = no test.

## Summary

| | Covered | Partial | Uncovered |
|---|---|---|---|
| Before Task 1 | 23 | 8 | 1 |
| After Task 1 | 30 | 2 | 0 |

Remaining partials are out of XCUITest's reach, not gaps we chose to leave: Sign in with Apple is a system
sheet, and the routine editor has no superset/progression controls (those change only through Claude
proposals, covered in 2.4); drag-to-reorder is covered at the data layer.

## 1 · Onboarding

| Step | Tests | Type | Status |
|---|---|---|---|
| 1.1 Welcome · Sign in with Apple | `OnboardingUITests::testFullOnboardingWithImport`, `::testSkipImportFinishesWithNoWorkouts` (welcome → skip); `AuthServiceTests` (all); `SyncSupportTests::sha256MatchesKnownVector`, `::randomNonceHasRequestedLengthAndCharset`; `SyncUITests` (email sign-up, E2E) | UI, Unit, E2E | partial — the Apple sheet is system UI and can't be driven; nonce/hash and auth error mapping are unit-tested |
| 1.2 Profile: units, body, goal, days, injuries | `OnboardingUITests::testFullOnboardingWithImport`, `::testProfileSetupShowsValidationErrorForMissingBodyweight`; `ProfileSetupInputTests` (all); `DomainLimitsTests::profileRanges` | UI, Unit | covered |
| 1.3 Import CSV + column mapping | `OnboardingUITests::testFullOnboardingWithImport` (bad row reported); `CSVParserTests`, `FitbodImporterTests`, `ImportPlanTests`, `ImportServiceTests`, `RealExportImportTests` | UI, Unit | covered |
| 1.4 Import result + match unknown exercises | `OnboardingUITests::testFullOnboardingWithImport` (two unmatched names → custom, 3 workouts in Log); `ImportPlanTests::unknownNameIsNeedsChoice`, `ImportServiceTests::customExercisesAreCreatedOnceAcrossWorkouts`, `ExerciseMatcherTests` | UI, Unit | covered |
| 1.5 Connect Claude (connector + OAuth) | `OnboardingUITests` (done / later); `EmptyStatesUITests::testTodayEmptyPlanStateOffersAskClaude`; `ProposalUITests::testClaudeScreenShowsConnectorPendingAndDisconnect`; `web/consent/server.test.mjs` (consent page, CSP, config); `mcp/auth_test.ts`, `mcp/http_test.ts` (401 + RFC 9728 metadata, OAuth-client-only tokens); `mcp_client.test.sql`; `OAuthGrantTransportTests` (E2E) | UI, HTTP, DB, E2E | covered — the claude.ai side of the OAuth round trip is manual |

## 2 · Plan

| Step | Tests | Type | Status |
|---|---|---|---|
| 2.1 Today: next routine + suggested weights | `ShellUITests::testTodayShowsSaturdayPushDay`; `SettingsUITests::testSwitchingUnitsToKgChangesTodayDisplay`; `TodayModelTests` (all); `ProgressionEngineTests` (all) | UI, Unit | covered |
| 2.2 My Plan: week schedule + routines | `PlanUITests::testPlanShowsWeekAndRoutines`; `WeekScheduleTests`, `RepositoryTests::scheduleAndRoutineForDate` | UI, Unit | covered |
| 2.3 Edit routine: order, sets, supersets, progression | `PlanUITests::testEditRoutineAddsExerciseAndChangesSets` (sets, add exercise); `EmptyStatesUITests::testTodayEmptyPlanStateOffersCreateRoutine`; `PlanChangeApplierTests::reorderMovesAndClamps`, `::supersetGroupsBothExercises`, `::progressionPolicyAndIncrement`; `MappingTests::routineRoundTripKeepsOrder`; `SmokeTests::newRoutineDraftUsesProgressionDefault` | UI, Unit | partial — drag-reorder isn't driven by XCUITest; supersets/progression have no editor controls (set via proposals, 2.4) |
| 2.4 Review Claude's proposal: apply / dismiss / undo | `ProposalUITests::testApplySubsetThenUndo`, `::testDismissAllRemovesTheChip`, `::testAutoApplyOnRelaunchAppliesTheProposal`; `ProposalSyncUITests` (E2E); `ProposalTests`, `ProposalModelTests`, `PlanChangeApplier*Tests`, `SyncEngineProposalTests`; `mcp/tools/write_test.ts` | UI, Unit, HTTP, E2E | covered |

## 3 · Workout

| Step | Tests | Type | Status |
|---|---|---|---|
| 3.1 In progress: workout clock, exercise list, finish | `WorkoutFlowUITests::testFullWorkoutWithRestPlatesAndRecords`; `ShellUITests::testStartWorkoutClosesAndKeepsSessionRunning`; `WorkoutClockTests`, `WorkoutSessionTests::pauseResumeAffectsElapsed` | UI, Unit | covered |
| 3.2 Log sets: warm-ups, reps × lb, Log Set | `WorkoutScreensUITests::testLoggingBasics`; `WorkoutFlowUITests::testEditConsecutiveFieldsWithoutLeavingScreen`; `WarmupGeneratorTests`, `SetFieldFormatTests`, `WorkoutSessionTests::logSetMarksNextUndoneAndStartsRest` | UI, Unit | covered |
| 3.3 Rest timer settings | **new** `FlowCoverageUITests::testStep3_3RestSettingsChangeTheNextRestDuration`; `RestTimerTests` (all); `WorkoutSessionTests::restDisabledSkipsRestTimer` | UI, Unit | covered (was partial) |
| 3.4 Plate calculator | `WorkoutFlowUITests::testFullWorkoutWithRestPlatesAndRecords`; `SettingsUITests::testPlatesEditorChangeReflectsInPlateCalculator`; `PlateCalculatorTests` | UI, Unit | covered |
| 3.5 How-to | **new** `FlowCoverageUITests::testStep3_5HowToOpensFromLogging` | UI | covered (was uncovered) |
| 3.6 Swap exercise | `WorkoutScreensUITests::testSwapReloadsProgressionHint`; `WorkoutFlowUITests::testSwapAndAddExerciseAndDiscard`; `WorkoutSessionTests::swapReconcilesMultiplierAndWeights`, `SessionPlannerTests::swapWeightFollowsHistoryOrKeeps` | UI, Unit | covered |
| 3.7 Exercise options: notes, warm-up, units, remove | **new** `FlowCoverageUITests::testStep3_7ExerciseNotePersistsAfterRelaunch`, **new** `::testStep3_7ExerciseOptionsAddWarmupAndRemove`; `WorkoutEditingTests::insertingWarmupGoesBeforeFirstWorkingSet`, `::removeSetEntryAndReplaceExercise`; `ExportServiceTests::csvExportsEntryNotesAndRoundTripsThem` | UI, Unit | covered (was partial) — units are switched app-wide (5.3) |
| 3.8 Add exercise mid-workout | `WorkoutFlowUITests::testSwapAndAddExerciseAndDiscard`; `EmptyStatesUITests::testLogEmptyStateResumesInProgressWorkout`; `SessionPlannerTests::adHocEntryUsesModeAwareDefaults` | UI, Unit | covered |
| 3.9 Finish: unfinished sets / discard | `WorkoutFlowUITests::testFullWorkoutWithRestPlatesAndRecords` (discard empty sets), `::testSwapAndAddExerciseAndDiscard` (discard workout); `WorkoutSessionTests::finishDiscardingUndoneSavesAndSummarizes`, `::discardCallsDiscard`, `::finishFailureReportsAndAllowsRetry` | UI, Unit | covered |
| 3.9a Finish long after the last set: end at the last set or now | `IdleFinishUITests::testFinishLongAfterTheLastSetEndsAtTheLastSet` (undone sets → `FinishSheet`), `::testDirectFinishWithAllSetsDoneAsksToo`; `IdleFinishTests` (threshold, no sets, pauses, never before start); `IdleFinishSessionTests` (shorter duration and calories, watch `finishedAt`); `WatchHealthRulesTests::theSaveWindowRunsFromFinishNotFromAnEarlierEnd` | UI, Unit | covered |
| 3.10 Complete: duration, records, volume, synced | `WorkoutFlowUITests::testFullWorkoutWithRestPlatesAndRecords` (sets, record); `WorkoutSummaryTests`, `RecordDetectorTests`, `WorkoutMetricsTests`; `SyncUITests::testWorkoutSyncsAcrossFreshInstall` (E2E) | UI, Unit, E2E | covered |

## 4 · History and body

| Step | Tests | Type | Status |
|---|---|---|---|
| 4.1 Log: week strip (minutes) + past workouts | `LogUITests::testLogShowsSeededWorkoutsWithDuration`, `::testLogPaginatesLazilyOnScroll`; `WeekActivityTests` | UI, Unit | covered |
| 4.2 Workout detail: edit / delete / share | `LogUITests::testEditWorkoutSet`, `::testEditTimedSetDuration`, `::testDeleteWorkout`; **new** `FlowCoverageUITests::testStep4_2WorkoutDetailSharesTheWorkout`; `WorkoutTextTests` (share text) | UI, Unit | covered (was partial) |
| 4.3 Exercise history + e1RM trend | `WorkoutScreensUITests::testHistoryChipShowsExerciseHistorySheet`; `BodyUITests::testStrengthRowPushesExerciseHistoryWithinBodyStack`; **new** `FlowCoverageUITests::testStep4_3ExerciseHistoryShowsTheE1RMTrend`; `ExerciseTrendsTests`, `OneRepMaxTests`, `SessionHistoryTests` | UI, Unit | covered (was partial) |
| 4.4 Body: goal + trends | `BodyUITests::testEmptyStateThenAddWeighIn`, `::testAddWeighInShowsTrendPendingWithoutEnoughDataForTrend`; **new** `FlowCoverageUITests::testStep4_4BodyShowsGoalProgressAndTrend`; `BodyTrendTests`, `BodyweightChartDomainTests` | UI, Unit | covered (was partial) |
| 4.5 Add weigh-in | `BodyUITests::testEmptyStateThenAddWeighIn`, `::testInvalidWeighInRejected`; `ProfileBodyRepositoryTests::bodyweightUpsertUpdatesExistingEntry`; `mcp/tools/write_test.ts` (log_bodyweight) | UI, Unit, HTTP | covered |

## 5 · Library and settings

| Step | Tests | Type | Status |
|---|---|---|---|
| 5.1 Library: search + filters | `LibraryUITests::testSearchAndOpenDetail`, `::testFilterByBodyPart`, `::testFilterByBodyPartReachesLastRowBySwiping`; `LibraryTests::searchByTextAndFilters` | UI, Unit | covered |
| 5.2 Create custom exercise | `LibraryUITests::testCreateCustomExercise`; `EmptyStatesUITests::testLibraryNoResultsOffersCreateCustomExercise`; **new** `FlowCoverageUITests::testStep5_2CustomExerciseIsUsableInRoutineAndWorkout`; `RepositoryTests::customExercises`, `DomainValidationTests::customExerciseNameLongerThan80IsRejected` | UI, Unit | covered (was partial) |
| 5.3 Settings: units, rest, plates, import/export, delete account | `SettingsUITests::testSwitchingUnitsToKgChangesTodayDisplay`, `::testPlatesEditorChangeReflectsInPlateCalculator`, `::testExportAllDataShowsShareSheet`, `::testEraseAllDataReturnsToOnboarding`; `SmokeTests::sessionsApplySavedRestPreference`; `ExportServiceTests`; `AuthIntegrationTests::deleteAccountRemovesUserAndData` (E2E) | UI, Unit, E2E | covered |
| 5.4 Claude connection + permissions | `ProposalUITests::testClaudeScreenShowsConnectorPendingAndDisconnect`, `::testAutoApplyOnRelaunchAppliesTheProposal`; `SettingsUITests::testClaudeBadgeDefaultsToNotConnected`; `ClaudeEnvironmentTests`, `ClaudeConnectionBadgeTests`; `mcp_hardening.test.sql`, `mcp_audit.test.sql`; `mcp/tools/read_test.ts` (permissions) | UI, Unit, DB, HTTP | covered |

## 6 · Edge cases

| Step | Tests | Type | Status |
|---|---|---|---|
| 6.1 Offline: log without signal, sync later | `SyncUITests::testOfflineLoggingSyncsLater` (E2E, `GYM_SIMULATE_OFFLINE`); `SyncEngineTests::offlineKeepsLocalDataDirty`; `SyncEngineSafetyTests::networkFailureIsNotRecordedAsARejection`; `SyncSupportTests::bannerForOfflineErrorAndConflicts` | E2E, Unit | covered |
| 6.2 Sync conflict | `ConflictUITests::testKeepThisIPhonesVersionClearsTheConflict` (keep local), `::testKeepOtherReplacesTheLocalWorkout` (keep remote) — hermetic `-seedConflict`; `SyncCoordinatorTests::conflictThenKeepLocalClearsAndCountsPending`, `::keepOtherAppliesRemoteAndNotifies`; `SyncStoreWorkoutTests::resolveConflict*`; `SyncRoundTripTests::staleWorkoutBecomesConflictAndKeepLocalWins` (E2E) | UI, Unit, E2E | covered |
| 6.3 Resume a workout after the app closes | `WorkoutFlowUITests::testResumeAfterRelaunch`; `EmptyStatesUITests::testLogEmptyStateResumesInProgressWorkout`; `SmokeTests::startSessionKeepsTheActiveWorkout`; `RepositoryTests::activeWorkoutExcludedFromHistory` | UI, Unit | covered |
| 6.4 Empty states | `EmptyStatesUITests` (Today, Log start/resume, Library no results); `BodyUITests::testEmptyStateThenAddWeighIn` | UI | covered |

## Flaky-test hardening (Task 1)

`ios/GymRollinsUITests/UITestSupport.swift` holds the shared helpers; the root causes are documented there.

| Test | Symptom | Root cause | Fix |
|---|---|---|---|
| `WorkoutScreensUITests::testLoggingBasics` | `workout.entry.0025` never appeared (line 12) | The "Start Workout" tap was lost: the xcresult's synthesized event hit (21, 782), the bottom-left corner of the 20…382 × 713…783 button frame and outside the glass capsule. The iOS 26 scroll-edge dimming overlay under the `.safeAreaInset` bar is an accessibility element; while it covered the button's centre, XCUITest's hit-point search picked the corner | `XCUIElement.tapCenter()` for bottom-bar glass buttons, `XCUIApplication.startWorkout()` (centre tap + wait for `workout.clock`), used by every test that starts a workout |
| `WorkoutFlowUITests::testFullWorkoutWithRestPlatesAndRecords` | `kAXErrorServerNotFound` "error getting main window" on the first tap after launch | The first query ran before the relaunched app's accessibility server was reachable | `launchReady`: terminate any old instance and wait for `.notRunning`, launch, wait for `.runningForeground` and a known first-screen element; bottom-bar taps via `tapCenter` |
| `BodyUITests::testAddWeighInShowsTrendPendingWithoutEnoughDataForTrend` | app killed ("signal kill") during a long run | No crash report was written (external SIGKILL, same launch-time family as above); the test also asserted `XCTAssertFalse(body.empty.waitForExistence(3))`, which fails at once if the empty text is still there during the sheet's dismissal | `launchReady`; `tapCenter` for "Add weigh-in" and "Save"; the empty-state check now waits for it to disappear (`waitForNonExistence`) |
